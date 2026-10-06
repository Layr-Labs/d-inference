package providerwrite

// Lanes retains the bounded per-connection mailboxes independently of the
// worker lifetime. Control priority is applied by Writer.Run, never by senders.
type Lanes struct {
	data    chan *Request
	control chan *Request
}

func NewLanes(data, control int) *Lanes {
	return &Lanes{data: make(chan *Request, data), control: make(chan *Request, control)}
}

func (l *Lanes) lane(control bool) chan *Request {
	if control {
		return l.control
	}
	return l.data
}

func (l *Lanes) Offer(req *Request, control bool, stopped <-chan struct{}) error {
	select {
	case l.lane(control) <- req:
		return nil
	case <-stopped:
		return ErrStopped
	default:
		return ErrQueueFull
	}
}

// Receive transfers queued ownership to the single lane consumer.
func (l *Lanes) Receive(control bool) <-chan *Request { return l.lane(control) }

func (l *Lanes) Depth(control bool) int { return len(l.lane(control)) }
