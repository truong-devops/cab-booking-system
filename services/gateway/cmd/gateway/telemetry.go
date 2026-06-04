package main

import (
	"context"
	"errors"
	"log"
	"net/url"
	"os"
	"strings"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/propagation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
	"go.opentelemetry.io/otel/trace"
)

type telemetryProvider struct {
	enabled bool
	tracer  trace.Tracer

	httpRequests metric.Int64Counter
	httpDuration metric.Float64Histogram
	depRequests  metric.Int64Counter
	depDuration  metric.Float64Histogram

	traceProvider *sdktrace.TracerProvider
	meterProvider *sdkmetric.MeterProvider
}

func initTelemetryProvider(cfg config) *telemetryProvider {
	if !parseBool(envOrDefault("OTEL_ENABLED", "true"), true) {
		log.Printf("[%s] OTel disabled", cfg.serviceName)
		return nil
	}

	serviceName := firstNonEmpty(
		strings.TrimSpace(os.Getenv("OTEL_SERVICE_NAME")),
		cfg.serviceName,
	)
	endpoint := envOrDefault("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4318")
	metricIntervalMS := parsePositiveInt(os.Getenv("OTEL_METRIC_EXPORT_INTERVAL_MS"), 60000)

	traceOpts, metricOpts := buildOTLPHTTPOtelOptions(endpoint)
	ctx := context.Background()

	traceExporter, err := otlptracehttp.New(ctx, traceOpts...)
	if err != nil {
		log.Printf("[%s] OTel trace exporter init error: %v", cfg.serviceName, err)
		return nil
	}
	metricExporter, err := otlpmetrichttp.New(ctx, metricOpts...)
	if err != nil {
		log.Printf("[%s] OTel metric exporter init error: %v", cfg.serviceName, err)
		return nil
	}

	res, err := resource.New(ctx, resource.WithAttributes(
		semconv.ServiceNameKey.String(serviceName),
	))
	if err != nil {
		log.Printf("[%s] OTel resource init error: %v", cfg.serviceName, err)
		return nil
	}

	traceProvider := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(traceExporter),
		sdktrace.WithResource(res),
	)
	metricReader := sdkmetric.NewPeriodicReader(
		metricExporter,
		sdkmetric.WithInterval(time.Duration(metricIntervalMS)*time.Millisecond),
	)
	meterProvider := sdkmetric.NewMeterProvider(
		sdkmetric.WithResource(res),
		sdkmetric.WithReader(metricReader),
	)

	otel.SetTracerProvider(traceProvider)
	otel.SetMeterProvider(meterProvider)
	otel.SetTextMapPropagator(
		propagation.NewCompositeTextMapPropagator(
			propagation.TraceContext{},
			propagation.Baggage{},
		),
	)

	tracer := otel.Tracer(serviceName)
	meter := otel.Meter(serviceName)

	httpRequests, err := meter.Int64Counter("gateway.http.requests")
	if err != nil {
		log.Printf("[%s] OTel counter init error (http requests): %v", cfg.serviceName, err)
		return nil
	}
	httpDuration, err := meter.Float64Histogram("gateway.http.duration.ms")
	if err != nil {
		log.Printf("[%s] OTel histogram init error (http duration): %v", cfg.serviceName, err)
		return nil
	}
	depRequests, err := meter.Int64Counter("gateway.dependency.requests")
	if err != nil {
		log.Printf("[%s] OTel counter init error (dependency requests): %v", cfg.serviceName, err)
		return nil
	}
	depDuration, err := meter.Float64Histogram("gateway.dependency.duration.ms")
	if err != nil {
		log.Printf("[%s] OTel histogram init error (dependency duration): %v", cfg.serviceName, err)
		return nil
	}

	log.Printf("[%s] OTel started", cfg.serviceName)
	return &telemetryProvider{
		enabled:       true,
		tracer:        tracer,
		httpRequests:  httpRequests,
		httpDuration:  httpDuration,
		depRequests:   depRequests,
		depDuration:   depDuration,
		traceProvider: traceProvider,
		meterProvider: meterProvider,
	}
}

func buildOTLPHTTPOtelOptions(endpoint string) ([]otlptracehttp.Option, []otlpmetrichttp.Option) {
	traceOpts := make([]otlptracehttp.Option, 0, 4)
	metricOpts := make([]otlpmetrichttp.Option, 0, 4)

	u, err := url.Parse(endpoint)
	if err != nil || strings.TrimSpace(u.Host) == "" {
		host := strings.TrimSpace(endpoint)
		host = strings.TrimPrefix(host, "http://")
		host = strings.TrimPrefix(host, "https://")
		traceOpts = append(traceOpts, otlptracehttp.WithEndpoint(host))
		metricOpts = append(metricOpts, otlpmetrichttp.WithEndpoint(host))
		if strings.HasPrefix(strings.ToLower(endpoint), "http://") {
			traceOpts = append(traceOpts, otlptracehttp.WithInsecure())
			metricOpts = append(metricOpts, otlpmetrichttp.WithInsecure())
		}
		return traceOpts, metricOpts
	}

	traceOpts = append(traceOpts, otlptracehttp.WithEndpoint(u.Host))
	metricOpts = append(metricOpts, otlpmetrichttp.WithEndpoint(u.Host))
	if strings.EqualFold(u.Scheme, "http") {
		traceOpts = append(traceOpts, otlptracehttp.WithInsecure())
		metricOpts = append(metricOpts, otlpmetrichttp.WithInsecure())
	}
	return traceOpts, metricOpts
}

func (t *telemetryProvider) Shutdown(ctx context.Context) error {
	if t == nil {
		return nil
	}
	var errs []error
	if t.traceProvider != nil {
		if err := t.traceProvider.Shutdown(ctx); err != nil {
			errs = append(errs, err)
		}
	}
	if t.meterProvider != nil {
		if err := t.meterProvider.Shutdown(ctx); err != nil {
			errs = append(errs, err)
		}
	}
	if len(errs) == 0 {
		return nil
	}
	return errors.Join(errs...)
}

func (t *telemetryProvider) StartRequestSpan(ctx context.Context, method, path string) (context.Context, trace.Span) {
	if t == nil || !t.enabled {
		return ctx, trace.SpanFromContext(ctx)
	}
	return t.tracer.Start(
		ctx,
		method+" "+path,
		trace.WithSpanKind(trace.SpanKindServer),
		trace.WithAttributes(
			attribute.String("http.method", method),
			attribute.String("http.path", path),
		),
	)
}

func (t *telemetryProvider) FinishRequestSpan(span trace.Span, statusCode int) {
	if t == nil || span == nil {
		return
	}
	span.SetAttributes(attribute.Int("http.status_code", statusCode))
	span.End()
}

func (t *telemetryProvider) RecordHTTP(ctx context.Context, method, path string, statusCode int, durationMs float64) {
	if t == nil {
		return
	}
	outcome := toOutcomeFromStatus(statusCode)
	attrs := metric.WithAttributes(
		attribute.String("http.method", method),
		attribute.String("http.path", path),
		attribute.Int("http.status_code", statusCode),
		attribute.String("outcome", outcome),
	)
	t.httpRequests.Add(ctx, 1, attrs)
	t.httpDuration.Record(ctx, durationMs, attrs)
}

func (t *telemetryProvider) RecordDependency(
	ctx context.Context,
	dependencyName string,
	operation string,
	attempt string,
	statusCode int,
	durationMs float64,
	err error,
) {
	if t == nil {
		return
	}
	outcome := "error"
	if err == nil {
		outcome = toOutcomeFromStatus(statusCode)
	}
	attrs := metric.WithAttributes(
		attribute.String("dependency.type", "http"),
		attribute.String("dependency.name", dependencyName),
		attribute.String("operation", operation),
		attribute.String("attempt", attempt),
		attribute.String("outcome", outcome),
	)
	if statusCode > 0 {
		attrs = metric.WithAttributes(
			attribute.String("dependency.type", "http"),
			attribute.String("dependency.name", dependencyName),
			attribute.String("operation", operation),
			attribute.String("attempt", attempt),
			attribute.String("outcome", outcome),
			attribute.Int("status_code", statusCode),
		)
	}
	if err != nil {
		attrs = metric.WithAttributes(
			attribute.String("dependency.type", "http"),
			attribute.String("dependency.name", dependencyName),
			attribute.String("operation", operation),
			attribute.String("attempt", attempt),
			attribute.String("outcome", outcome),
			attribute.String("error_type", err.Error()),
		)
	}

	t.depRequests.Add(ctx, 1, attrs)
	t.depDuration.Record(ctx, durationMs, attrs)
}

func toOutcomeFromStatus(status int) string {
	switch {
	case status >= 500:
		return "error"
	case status >= 400:
		return "deny"
	default:
		return "ok"
	}
}

func injectTraceContext(ctx context.Context, headers map[string]string) {
	carrier := propagation.MapCarrier(headers)
	otel.GetTextMapPropagator().Inject(ctx, carrier)
}
