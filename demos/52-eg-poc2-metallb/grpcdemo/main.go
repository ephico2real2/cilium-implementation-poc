// grpcdemo — in-memory shop.v1.Orders for demo 52.
//
// Four RPCs, the same three catalogue rows as shop-db, health for "" and
// shop.v1.Orders, server reflection. Every response carries served_by
// (POD_NAME) and version (VERSION); the same values go out as response
// metadata x-served-by / x-version.
package main

import (
	"context"
	"log"
	"net"
	"os"
	"time"

	shopv1 "grpcdemo/gen/shop/v1"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/reflection"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

const defaultAddr = ":9090"

var catalog = []*shopv1.Order{
	{Id: 1, Item: "keyboard", AmountCents: 4999},
	{Id: 2, Item: "mouse", AmountCents: 1999},
	{Id: 3, Item: "monitor", AmountCents: 24900},
}

type server struct {
	shopv1.UnimplementedOrdersServer
	servedBy string
	version  string
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func newServer() *server {
	return &server{
		servedBy: envOr("POD_NAME", "grpcdemo"),
		version:  envOr("VERSION", "v1"),
	}
}

func (s *server) setMD(ctx context.Context) {
	_ = grpc.SetHeader(ctx, metadata.Pairs(
		"x-served-by", s.servedBy,
		"x-version", s.version,
	))
}

func (s *server) stamp(o *shopv1.Order) *shopv1.Order {
	cp := proto.Clone(o).(*shopv1.Order)
	cp.ServedBy = s.servedBy
	cp.Version = s.version
	return cp
}

func (s *server) ListOrders(ctx context.Context, _ *shopv1.ListOrdersRequest) (*shopv1.ListOrdersResponse, error) {
	s.setMD(ctx)
	out := make([]*shopv1.Order, 0, len(catalog))
	for _, o := range catalog {
		out = append(out, s.stamp(o))
	}
	return &shopv1.ListOrdersResponse{
		Orders:   out,
		ServedBy: s.servedBy,
		Version:  s.version,
	}, nil
}

func (s *server) GetOrder(ctx context.Context, req *shopv1.GetOrderRequest) (*shopv1.Order, error) {
	s.setMD(ctx)
	for _, o := range catalog {
		if o.GetId() == req.GetId() {
			return s.stamp(o), nil
		}
	}
	return nil, status.Errorf(codes.NotFound, "order %d not found", req.GetId())
}

func (s *server) WatchOrders(req *shopv1.WatchOrdersRequest, stream shopv1.Orders_WatchOrdersServer) error {
	s.setMD(stream.Context())
	n := req.GetCount()
	interval := time.Duration(req.GetIntervalMs()) * time.Millisecond
	if interval <= 0 {
		interval = time.Millisecond
	}
	for i := int32(0); i < n; i++ {
		o := catalog[int(i)%len(catalog)]
		ev := &shopv1.OrderEvent{
			Order:    s.stamp(o),
			ServedBy: s.servedBy,
			Version:  s.version,
		}
		if err := stream.Send(ev); err != nil {
			return err
		}
		if i+1 < n {
			t := time.NewTimer(interval)
			select {
			case <-stream.Context().Done():
				t.Stop()
				return stream.Context().Err()
			case <-t.C:
			}
		}
	}
	return nil
}

func (s *server) SlowOrder(ctx context.Context, req *shopv1.SlowOrderRequest) (*shopv1.Order, error) {
	s.setMD(ctx)
	d := time.Duration(req.GetDelayMs()) * time.Millisecond
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-t.C:
		return s.stamp(catalog[0]), nil
	}
}

func newGRPCServer(s *server) *grpc.Server {
	gs := grpc.NewServer()
	shopv1.RegisterOrdersServer(gs, s)
	hs := health.NewServer()
	hs.SetServingStatus("", healthpb.HealthCheckResponse_SERVING)
	hs.SetServingStatus("shop.v1.Orders", healthpb.HealthCheckResponse_SERVING)
	healthpb.RegisterHealthServer(gs, hs)
	reflection.Register(gs)
	return gs
}

func main() {
	addr := defaultAddr
	if v := os.Getenv("ADDR"); v != "" {
		addr = v
	}
	lis, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatalf("listen %s: %v", addr, err)
	}
	s := newServer()
	log.Printf("grpcdemo served_by=%s version=%s on %s", s.servedBy, s.version, addr)
	if err := newGRPCServer(s).Serve(lis); err != nil {
		log.Fatal(err)
	}
}
