package store

// rowScanner is the decoding boundary shared by pgx.Row and pgx.Rows. Query
// selection and error policy remain with each store operation.
type rowScanner interface {
	Scan(dest ...any) error
}
