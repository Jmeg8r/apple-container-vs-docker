# Realistic multi-stage build for scenario 06 (build speed + cache behavior).
# Stage 1 compiles a static Go binary; stage 2 ships only the binary on a tiny base.
# --target build lets us measure the heavy stage in isolation if needed.
FROM docker.io/library/golang:1.23 AS build
WORKDIR /src
COPY go.mod .
COPY main.go .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /out/app ./...

FROM docker.io/library/alpine:3.20 AS final
COPY --from=build /out/app /usr/local/bin/app
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/app"]
