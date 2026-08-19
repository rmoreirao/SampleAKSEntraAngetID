from __future__ import annotations

from azure.identity import DefaultAzureCredential
from azure.monitor.opentelemetry.exporter import AzureMonitorTraceExporter
from fastapi import FastAPI
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

from .settings import Settings

_provider: TracerProvider | None = None


def configure_telemetry(app: FastAPI, settings: Settings) -> None:
    global _provider
    if _provider is None:
        resource = Resource.create(
            {"service.name": settings.otel_service_name or settings.service_name}
        )
        _provider = TracerProvider(resource=resource)
        if settings.otel_exporter_otlp_endpoint:
            _provider.add_span_processor(
                BatchSpanProcessor(
                    OTLPSpanExporter(endpoint=str(settings.otel_exporter_otlp_endpoint))
                )
            )
        if settings.applicationinsights_connection_string:
            credential = DefaultAzureCredential(
                managed_identity_client_id=settings.uami_client_id
            )
            _provider.add_span_processor(
                BatchSpanProcessor(
                    AzureMonitorTraceExporter(
                        connection_string=settings.applicationinsights_connection_string,
                        credential=credential,
                    )
                )
            )
        trace.set_tracer_provider(_provider)
    FastAPIInstrumentor.instrument_app(app, tracer_provider=_provider)
