#!/usr/bin/env bash
# gen.sh — regenerate shop.v1 from proto/shop/v1/orders.proto without a
# system protoc. Pins from `go list -m -versions` on 2026-09-19:
#
#   github.com/bufbuild/buf                          v1.73.0
#   google.golang.org/protobuf                       v1.36.12
#     (google.golang.org/protobuf/cmd/protoc-gen-go)
#   google.golang.org/grpc/cmd/protoc-gen-go-grpc    v1.6.2
#
# Usage: demos/52-eg-poc2-metallb/grpcdemo/gen.sh
set -euo pipefail
cd "$(dirname "$0")"
go run github.com/bufbuild/buf/cmd/buf@v1.73.0 generate
