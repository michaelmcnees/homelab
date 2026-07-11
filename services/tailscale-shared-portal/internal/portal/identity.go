package portal

import "context"

type Identity struct {
	LoginName  string
	NodeName   string
	NodeID     string
	RemoteAddr string
}

type IdentityResolver interface {
	Resolve(ctx context.Context, remoteAddr string) (Identity, error)
}
