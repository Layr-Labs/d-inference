package mdm

import (
	"context"
	"errors"
	"fmt"
	"time"
)

type securityInfoWaiter struct {
	commandUUID string
	ch          chan *SecurityInfoResponse
	early       map[string]*SecurityInfoResponse
}

const maxEarlySecurityInfoResponses = 4

func (c *Client) bufferEarlySecurityInfo(
	udid, commandUUID string,
	resp *SecurityInfoResponse,
) bool {
	if udid == "" || commandUUID == "" || resp == nil {
		return false
	}
	c.waitMu.Lock()
	defer c.waitMu.Unlock()
	waiter, ok := c.secInfoWaiters[udid]
	if !ok || waiter.commandUUID != "" {
		return false
	}
	if waiter.early == nil {
		waiter.early = make(map[string]*SecurityInfoResponse)
	}
	if _, exists := waiter.early[commandUUID]; !exists &&
		len(waiter.early) >= maxEarlySecurityInfoResponses {
		return false
	}
	waiter.early[commandUUID] = resp
	c.secInfoWaiters[udid] = waiter
	return true
}

// registerSecurityInfoWaiter installs exclusive one-shot command ownership for
// a UDID. It rejects overlap rather than replacing a live attempt's channel.
func (c *Client) registerSecurityInfoWaiter(
	udid string,
) (<-chan *SecurityInfoResponse, func(string) bool, func(), error) {
	ch := make(chan *SecurityInfoResponse, 1)
	c.waitMu.Lock()
	if _, exists := c.secInfoWaiters[udid]; exists {
		c.waitMu.Unlock()
		return nil, nil, nil, fmt.Errorf("%w: SecurityInfo", ErrWaiterAlreadyRegistered)
	}
	c.secInfoWaiters[udid] = securityInfoWaiter{ch: ch}
	c.waitMu.Unlock()
	bind := func(commandUUID string) bool {
		c.waitMu.Lock()
		cur, ok := c.secInfoWaiters[udid]
		if !ok || cur.ch != ch || cur.commandUUID != "" || commandUUID == "" {
			c.waitMu.Unlock()
			return false
		}
		cur.commandUUID = commandUUID
		early := cur.early[commandUUID]
		if early != nil {
			delete(c.secInfoWaiters, udid)
		} else {
			c.secInfoWaiters[udid] = cur
		}
		c.waitMu.Unlock()
		if early != nil {
			c.consumeCommand(commandUUID, time.Now())
			ch <- early
		}
		return true
	}
	release := func() {
		c.waitMu.Lock()
		if cur, ok := c.secInfoWaiters[udid]; ok && cur.ch == ch {
			delete(c.secInfoWaiters, udid)
		}
		c.waitMu.Unlock()
	}
	return ch, bind, release, nil
}

// awaitSecurityInfo blocks on a previously-registered waiter channel until the
// response arrives, ctx is cancelled, or the timeout elapses.
func awaitSecurityInfo(ctx context.Context, ch <-chan *SecurityInfoResponse, timeout time.Duration) (*SecurityInfoResponse, error) {
	select {
	case resp := <-ch:
		return resp, nil
	case <-ctx.Done():
		return nil, fmt.Errorf("SecurityInfo wait cancelled: %w", ctx.Err())
	case <-time.After(timeout):
		return nil, errors.New("timeout waiting for SecurityInfo")
	}
}
