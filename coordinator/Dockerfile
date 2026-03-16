FROM golang:1.24-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o coordinator ./cmd/coordinator

FROM alpine:3.21
RUN apk add --no-cache ca-certificates
COPY --from=builder /app/coordinator /usr/local/bin/coordinator
EXPOSE 8080
CMD ["coordinator"]
