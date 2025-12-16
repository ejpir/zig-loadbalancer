FROM alpine:latest

RUN apk add --no-cache zig netcat-openbsd

WORKDIR /app

COPY . .

RUN zig build -Doptimize=ReleaseFast

EXPOSE 8080

CMD ["./zig-out/bin/load_balancer_mp", "--workers", "4", "--port", "8080"]
