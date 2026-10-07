package registry_test

import (
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/providerwrite"
	"nhooyr.io/websocket"
)

type writerFixture struct {
	*providerwrite.Writer
	lanes     *providerwrite.Lanes
	transport *frameTransport
}

type frameTransport struct {
	write func([]byte) error
	stop  chan struct{}
	once  sync.Once
	mu    sync.Mutex
	last  []byte
}

func (f *frameTransport) Write(data []byte) error {
	select {
	case <-f.stop:
		return providerwrite.ErrStopped
	default:
	}
	f.mu.Lock()
	f.last = append([]byte(nil), data...)
	f.mu.Unlock()
	if f.write == nil {
		return nil
	}
	return f.write(data)
}

func (f *frameTransport) Close() { f.once.Do(func() { close(f.stop) }) }

func (f *frameTransport) Watch(stop, writerStop <-chan struct{}) {
	select {
	case <-stop:
	case <-writerStop:
	}
}

func newWriterFixture(data, control int, conn *websocket.Conn, timeout func(int) time.Duration, write func([]byte) error, stop chan struct{}) *writerFixture {
	lanes := providerwrite.NewLanes(data, control)
	var transport providerwrite.Transport
	if conn != nil {
		transport = providerwrite.NewSocketTransport(conn, timeout)
	} else {
		if stop == nil {
			stop = make(chan struct{})
		}
		transport = &frameTransport{write: write, stop: stop}
	}
	fixture := &writerFixture{Writer: providerwrite.New(transport, lanes), lanes: lanes}
	fixture.transport, _ = transport.(*frameTransport)
	return fixture
}

func (f *writerFixture) offer(req *providerwrite.Request, control bool) {
	if err := f.lanes.Offer(req, control, f.Done()); err != nil {
		panic(err)
	}
}

func (f *writerFixture) take(control bool) *providerwrite.Request {
	return <-f.lanes.Receive(control)
}

// executeUntilPublication uses the production execution and publication stages
// with an explicit barrier, rather than pausing a worker through a test hook.
func (f *writerFixture) executeUntilPublication(control bool, entered, release chan struct{}) {
	req := f.take(control)
	f.Execute(req)
	close(entered)
	<-release
	req.Publish()
}
