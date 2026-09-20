package main

import (
	"context"
	"io"
	"net"
	"testing"
	"time"

	shopv1 "grpcdemo/gen/shop/v1"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"
)

const bufSize = 1024 * 1024

func testClient(t *testing.T, s *server) shopv1.OrdersClient {
	t.Helper()
	lis := bufconn.Listen(bufSize)
	gs := newGRPCServer(s)
	go func() { _ = gs.Serve(lis) }()
	t.Cleanup(func() { gs.Stop(); _ = lis.Close() })
	conn, err := grpc.NewClient("passthrough:///bufnet",
		grpc.WithContextDialer(func(context.Context, string) (net.Conn, error) {
			return lis.Dial()
		}),
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return shopv1.NewOrdersClient(conn)
}

func TestListOrders(t *testing.T) {
	s := &server{servedBy: "grpcdemo-v1-abc", version: "v1"}
	c := testClient(t, s)
	resp, err := c.ListOrders(context.Background(), &shopv1.ListOrdersRequest{})
	if err != nil {
		t.Fatalf("ListOrders: %v", err)
	}
	if resp.GetVersion() != "v1" || resp.GetServedBy() != "grpcdemo-v1-abc" {
		t.Fatalf("meta version=%q served_by=%q", resp.GetVersion(), resp.GetServedBy())
	}
	if len(resp.GetOrders()) != 3 {
		t.Fatalf("want 3 orders, got %d", len(resp.GetOrders()))
	}
	want := []struct {
		id     int64
		item   string
		cents  int64
	}{
		{1, "keyboard", 4999},
		{2, "mouse", 1999},
		{3, "monitor", 24900},
	}
	for i, w := range want {
		o := resp.Orders[i]
		if o.GetId() != w.id || o.GetItem() != w.item || o.GetAmountCents() != w.cents {
			t.Fatalf("order[%d]=%v want id=%d item=%s cents=%d", i, o, w.id, w.item, w.cents)
		}
		if o.GetVersion() != "v1" || o.GetServedBy() != "grpcdemo-v1-abc" {
			t.Fatalf("order[%d] meta version=%q served_by=%q", i, o.GetVersion(), o.GetServedBy())
		}
	}
}

func TestGetOrder(t *testing.T) {
	s := &server{servedBy: "grpcdemo-v2-xyz", version: "v2"}
	c := testClient(t, s)
	o, err := c.GetOrder(context.Background(), &shopv1.GetOrderRequest{Id: 2})
	if err != nil {
		t.Fatalf("GetOrder(2): %v", err)
	}
	if o.GetItem() != "mouse" || o.GetAmountCents() != 1999 || o.GetVersion() != "v2" {
		t.Fatalf("GetOrder(2)=%v", o)
	}
	_, err = c.GetOrder(context.Background(), &shopv1.GetOrderRequest{Id: 99})
	if status.Code(err) != codes.NotFound {
		t.Fatalf("GetOrder(99) code=%v want NotFound (err=%v)", status.Code(err), err)
	}
}

func TestWatchOrders(t *testing.T) {
	s := &server{servedBy: "grpcdemo-v1-abc", version: "v1"}
	c := testClient(t, s)
	stream, err := c.WatchOrders(context.Background(), &shopv1.WatchOrdersRequest{
		Count:      5,
		IntervalMs: 1,
	})
	if err != nil {
		t.Fatalf("WatchOrders: %v", err)
	}
	var n int
	for {
		ev, err := stream.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatalf("Recv: %v", err)
		}
		if ev.GetOrder() == nil || ev.GetVersion() != "v1" {
			t.Fatalf("event=%v", ev)
		}
		n++
	}
	if n != 5 {
		t.Fatalf("want 5 events, got %d", n)
	}
}

func TestSlowOrder(t *testing.T) {
	s := &server{servedBy: "grpcdemo-v1-abc", version: "v1"}
	c := testClient(t, s)

	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	_, err := c.SlowOrder(ctx, &shopv1.SlowOrderRequest{DelayMs: 3000})
	if status.Code(err) != codes.DeadlineExceeded && status.Code(err) != codes.Canceled {
		t.Fatalf("SlowOrder cancelled: code=%v err=%v", status.Code(err), err)
	}

	o, err := c.SlowOrder(context.Background(), &shopv1.SlowOrderRequest{DelayMs: 1})
	if err != nil {
		t.Fatalf("SlowOrder(1ms): %v", err)
	}
	if o.GetItem() != "keyboard" || o.GetVersion() != "v1" {
		t.Fatalf("SlowOrder=%v", o)
	}
}
