# syntax=docker/dockerfile:1

# ---- build stage ---------------------------------------------------------
FROM golang:1.24-alpine AS build

ARG VERSION=dev
WORKDIR /src

# Standard library only: go.mod has no requirements, so there is nothing to
# download. Copying it first still keeps the layer cache stable.
COPY go.mod ./
# Broken on purpose for the failed-revision demo: this file does not exist.
COPY missing-file-on-purpose.txt /nonexistent/
COPY . .

RUN CGO_ENABLED=0 GOOS=linux go build \
      -trimpath \
      -ldflags="-s -w -X main.version=${VERSION}" \
      -o /out/podinfo-sls .

# ---- runtime stage -------------------------------------------------------
FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=build /out/podinfo-sls /podinfo-sls

ENV PORT=9898
EXPOSE 9898

ENTRYPOINT ["/podinfo-sls"]
