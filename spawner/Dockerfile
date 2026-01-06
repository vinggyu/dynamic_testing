FROM docker.io/library/golang:1.24-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -o /spawner .

FROM alpine:latest
WORKDIR /
COPY --from=builder /spawner /spawner
EXPOSE 1337
CMD ["/spawner"]
