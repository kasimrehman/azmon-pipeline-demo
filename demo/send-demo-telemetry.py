import argparse
import json
import logging
import signal
import socket
import sys
import time
import uuid
from datetime import datetime, timezone

from opentelemetry import _logs
from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.sdk.resources import Resource


EVENT_PATTERN = (
    ("health", "DEBUG", logging.DEBUG, 7),
    ("health", "DEBUG", logging.DEBUG, 7),
    ("transaction", "INFO", logging.INFO, 6),
    ("health", "DEBUG", logging.DEBUG, 7),
    ("transaction", "INFO", logging.INFO, 6),
    ("health", "DEBUG", logging.DEBUG, 7),
    ("transaction", "INFO", logging.INFO, 6),
    ("health", "DEBUG", logging.DEBUG, 7),
    ("warning", "WARNING", logging.WARNING, 4),
    ("error", "ERROR", logging.ERROR, 3),
)

stop_requested = False


class CheckedOTLPLogExporter(OTLPLogExporter):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.export_results = []

    def export(self, batch):
        result = super().export(batch)
        self.export_results.append(result)
        return result


def request_stop(_signum, _frame):
    global stop_requested
    stop_requested = True


def parse_args():
    parser = argparse.ArgumentParser(description="Send bounded Syslog and OTLP demo traffic.")
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--duration-seconds", type=float, required=True)
    parser.add_argument("--events-per-second", type=int, required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--syslog-port", type=int, default=514)
    parser.add_argument("--otlp-port", type=int, default=4317)
    parser.add_argument("--timeout-seconds", type=int, default=10)
    return parser.parse_args()


def utc_now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def connect_syslog(args):
    connection = socket.create_connection(
        (args.endpoint, args.syslog_port), timeout=args.timeout_seconds
    )
    connection.settimeout(args.timeout_seconds)
    return connection


def create_otlp_logger(args):
    provider = LoggerProvider(
        resource=Resource.create({"service.name": "arc-monitor-showcase"})
    )
    exporter = CheckedOTLPLogExporter(
        endpoint=f"{args.endpoint}:{args.otlp_port}",
        insecure=True,
        timeout=args.timeout_seconds,
    )
    provider.add_log_record_processor(
        BatchLogRecordProcessor(
            exporter,
            schedule_delay_millis=1000,
            max_export_batch_size=256,
        )
    )
    _logs.set_logger_provider(provider)

    logger = logging.getLogger("arc.monitor.showcase")
    logger.handlers.clear()
    logger.propagate = False
    logger.setLevel(logging.DEBUG)
    logger.addHandler(LoggingHandler(level=logging.DEBUG, logger_provider=provider))
    return logger, provider, exporter


def event_for(run_id, sequence):
    event_class, severity_text, log_level, syslog_severity = EVENT_PATTERN[
        (sequence - 1) % len(EVENT_PATTERN)
    ]
    duration_ms = float(20 + ((sequence * 37) % 480))
    trace_id = uuid.uuid5(uuid.NAMESPACE_URL, f"demo:{run_id}:{sequence}").hex
    return event_class, severity_text, log_level, syslog_severity, duration_ms, trace_id


def send_syslog(connection, args, sequence, event):
    event_class, severity_text, _log_level, syslog_severity, duration_ms, trace_id = event
    priority = 8 + syslog_severity
    timestamp = utc_now()
    body = (
        f"run_id={args.run_id} sequence={sequence} site=edge-01 "
        f"environment=demo event_class={event_class} severity={severity_text} "
        f"duration_ms={duration_ms:.0f} trace_id={trace_id} "
        "email=demo.user@example.com token=demo-token-123"
    )
    message = (
        f"<{priority}>1 {timestamp} demo-sender arc-monitor-demo {sequence} "
        f"DEMO - {body}\n"
    )
    connection.sendall(message.encode("utf-8"))


def send_otlp(logger, args, sequence, event):
    event_class, severity_text, log_level, _syslog_severity, duration_ms, trace_id = event
    body = (
        f"run_id={args.run_id} sequence={sequence} event_class={event_class} "
        "email=demo.user@example.com token=demo-token-123"
    )
    logger.log(
        log_level,
        body,
        extra={
            "DemoRunId": args.run_id,
            "SequenceNumber": sequence,
            "ServiceName": "checkout-api",
            "DeploymentEnvironment": "demo",
            "Site": "edge-01",
            "TraceId": trace_id,
            "DurationMs": duration_ms,
            "EventClass": event_class,
            "SeverityText": severity_text,
        },
    )


def main():
    args = parse_args()
    signal.signal(signal.SIGINT, request_stop)
    if hasattr(signal, "SIGTERM"):
        signal.signal(signal.SIGTERM, request_stop)

    started_at = utc_now()
    deadline = time.monotonic() + args.duration_seconds
    interval = 1.0 / args.events_per_second
    next_send = time.monotonic()
    counts = {
        "syslog": 0,
        "otlp": 0,
        "health": 0,
        "transaction": 0,
        "warning": 0,
        "error": 0,
    }

    syslog_connection = connect_syslog(args)
    logger, provider, exporter = create_otlp_logger(args)
    sequence = 0

    print(
        json.dumps(
            {
                "status": "started",
                "runId": args.run_id,
                "endpoint": args.endpoint,
                "eventsPerSecondPerProtocol": args.events_per_second,
                "startedUtc": started_at,
            }
        ),
        flush=True,
    )

    try:
        while not stop_requested and time.monotonic() < deadline:
            sequence += 1
            event = event_for(args.run_id, sequence)
            send_syslog(syslog_connection, args, sequence, event)
            counts["syslog"] += 1
            send_otlp(logger, args, sequence, event)
            counts["otlp"] += 1
            counts[event[0]] += 1

            if sequence % max(args.events_per_second * 10, 1) == 0:
                print(
                    json.dumps(
                        {
                            "status": "running",
                            "runId": args.run_id,
                            "sequence": sequence,
                            "syslogSent": counts["syslog"],
                            "otlpQueued": counts["otlp"],
                            "timestampUtc": utc_now(),
                        }
                    ),
                    flush=True,
                )

            next_send += interval
            delay = next_send - time.monotonic()
            if delay > 0:
                time.sleep(delay)
    finally:
        syslog_connection.close()
        flushed = provider.force_flush(timeout_millis=args.timeout_seconds * 1000)
        provider.shutdown()
        export_succeeded = bool(exporter.export_results) and all(
            getattr(result, "name", "") == "SUCCESS"
            for result in exporter.export_results
        )

    summary = {
        "status": "stopped" if stop_requested else "completed",
        "runId": args.run_id,
        "startedUtc": started_at,
        "stoppedUtc": utc_now(),
        "otlpFlushSucceeded": bool(flushed),
        "otlpExportSucceeded": export_succeeded,
        "counts": counts,
    }
    print(json.dumps(summary), flush=True)
    return 0 if flushed and export_succeeded else 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(json.dumps({"status": "failed", "error": str(error)}), file=sys.stderr)
        sys.exit(1)
