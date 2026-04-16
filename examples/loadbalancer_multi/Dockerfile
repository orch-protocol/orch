FROM golang:1.23-alpine AS builder

WORKDIR /app

# Copy go.mod and go.sum if they exist
COPY go.mod go.sum ./
RUN go mod download

# Copy the entire project
COPY . .

# Build LB
RUN go build -o lb_bin ./examples/loadbalancer_multi/lb/main.go
# Build Server
RUN go build -o server_bin ./examples/loadbalancer_multi/server/main.go

FROM alpine:latest
WORKDIR /app
RUN apk add --no-cache docker-cli
COPY --from=builder /app/lb_bin .
COPY --from=builder /app/server_bin .

EXPOSE 8000 7945 7946

# Start script
RUN echo '#!/bin/sh' > /app/run.sh && \
    echo 'if [ "$TYPE" = "lb" ]; then ./lb_bin; else ./server_bin; fi' >> /app/run.sh && \
    chmod +x /app/run.sh

CMD ["/app/run.sh"]
