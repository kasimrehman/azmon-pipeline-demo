import argparse
import json
import logging
import os
import signal
import socket
import sys
import time
import uuid
from datetime import datetime, timezone

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


def request_stop(_signum, _frame):
    global stop_requested
    stop_requested = True


def parse_args():
    parser = argparse.ArgumentParser(
        description="Generate bounded Syslog and OTLP demo traffic."
    )
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--duration-seconds", type=float, required=True)
    parser.add_argument("--events-per-second", type=int, required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument(
        "--protocol",
        choices=("syslog", "otlp", "both"),
        default="both",
    )
    parser.add_argument("--syslog-port", type=int, default=514)
    parser.add_argument("--otlp-port", type=int, default=4317)
    parser.add_argument("--timeout-seconds", type=int, default=10)
    parser.add_argument("--stop-file")
    parser.add_argument("--show-payload-sample", action="store_true")
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
    from opentelemetry import _logs
    from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter
    from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
    from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
    from opentelemetry.sdk.resources import Resource

    class CheckedOTLPLogExporter(OTLPLogExporter):
        def __init__(self, **kwargs):
            super().__init__(**kwargs)
            self.export_results = []

        def export(self, batch):
            result = super().export(batch)
            self.export_results.append(result)
            return result

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


def create_syslog_message(args, sequence, event):
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
    return message


def send_syslog(connection, args, sequence, event):
    message = create_syslog_message(args, sequence, event)
    connection.sendall(message.encode("utf-8"))
    return message


def create_otlp_payload(args, sequence, event):
    event_class, severity_text, log_level, _syslog_severity, duration_ms, trace_id = event
    body = (
        f"run_id={args.run_id} sequence={sequence} event_class={event_class} "
        "email=demo.user@example.com token=demo-token-123"
    )
    attributes = {
        "DemoRunId": args.run_id,
        "SequenceNumber": sequence,
        "ServiceName": "checkout-api",
        "DeploymentEnvironment": "demo",
        "Site": "edge-01",
        "TraceId": trace_id,
        "DurationMs": duration_ms,
        "EventClass": event_class,
        "SeverityText": severity_text,
    }
    return body, attributes, log_level


def send_otlp(logger, args, sequence, event):
    body, attributes, log_level = create_otlp_payload(args, sequence, event)
    logger.log(
        log_level,
        body,
        extra=attributes,
    )
    return body, attributes


def describe_message_variation(args, syslog_enabled, otlp_enabled):
    description = {
        "sameForEveryMessage": [
            f"run ID remains {args.run_id}",
            "site remains edge-01",
            "environment remains demo",
            "synthetic email and token remain fixed before pipeline redaction",
        ],
        "differentForLaterMessages": [
            "sequence and Syslog process ID increase by one",
            "event timestamp is generated immediately before each send",
            "event class and severity follow the repeating ten-message pattern",
            "duration is deterministically derived from sequence",
            "trace ID is deterministically derived from run ID and sequence",
        ],
        "tenMessagePattern": [
            "health DEBUG",
            "health DEBUG",
            "transaction INFO",
            "health DEBUG",
            "transaction INFO",
            "health DEBUG",
            "transaction INFO",
            "health DEBUG",
            "warning WARNING",
            "error ERROR",
        ],
    }
    if syslog_enabled:
        description["sameForEverySyslogMessage"] = [
            "host remains demo-sender",
            "application remains arc-monitor-demo",
            "message ID remains DEMO",
        ]
    if otlp_enabled:
        description["sameForEveryOtlpMessage"] = [
            "service name remains checkout-api",
            "OTLP resource service name remains arc-monitor-showcase",
        ]
    return description


def print_message_variation(args, syslog_enabled, otlp_enabled):
    description = describe_message_variation(args, syslog_enabled, otlp_enabled)
    sections = (
        ("The following stays the same:", "sameForEveryMessage"),
        ("The following changes:", "differentForLaterMessages"),
        ("Repeating ten-message pattern:", "tenMessagePattern"),
        ("Syslog fields that stay the same:", "sameForEverySyslogMessage"),
        ("OTLP fields that stay the same:", "sameForEveryOtlpMessage"),
    )

    print("\nHow later messages compare with the first message:")
    for heading, key in sections:
        values = description.get(key)
        if not values:
            continue
        print(f"\n{heading}")
        for value in values:
            print(f"  - {value}")
    print()


def main():
    args = parse_args()
    signal.signal(signal.SIGINT, request_stop)
    if hasattr(signal, "SIGTERM"):
        signal.signal(signal.SIGTERM, request_stop)

    started_at = utc_now()
    interval = 1.0 / args.events_per_second
    counts = {
        "syslog": 0,
        "otlp": 0,
        "health": 0,
        "transaction": 0,
        "warning": 0,
        "error": 0,
    }

    syslog_enabled = args.protocol in ("syslog", "both")
    otlp_enabled = args.protocol in ("otlp", "both")
    syslog_connection = connect_syslog(args) if syslog_enabled else None
    logger = provider = exporter = None
    if otlp_enabled:
        logger, provider, exporter = create_otlp_logger(args)
    sequence = 0
    deadline = time.monotonic() + args.duration_seconds
    next_send = time.monotonic()

    print(
        json.dumps(
            {
                "status": "started",
                "runId": args.run_id,
                "endpoint": args.endpoint,
                "protocol": args.protocol,
                "eventsPerSecondPerProtocol": args.events_per_second,
                "startedUtc": started_at,
            }
        ),
        flush=True,
    )

    try:
        while (
            not stop_requested
            and not (args.stop_file and os.path.exists(args.stop_file))
            and time.monotonic() < deadline
        ):
            sequence += 1
            event = event_for(args.run_id, sequence)
            syslog_message = None
            otlp_body = otlp_attributes = None
            if syslog_enabled:
                syslog_message = send_syslog(
                    syslog_connection, args, sequence, event
                )
                counts["syslog"] += 1
            if otlp_enabled:
                otlp_body, otlp_attributes = send_otlp(
                    logger, args, sequence, event
                )
                counts["otlp"] += 1
            counts[event[0]] += 1

            if args.show_payload_sample and sequence == 1:
                sample = {
                    "status": "first-source-message",
                    "note": "This is the actual first message sent before edge processing; synthetic values only.",
                    "sequence": sequence,
                }
                if syslog_enabled:
                    sample["syslogWireMessage"] = syslog_message.rstrip("\n")
                if otlp_enabled:
                    sample["otlpBody"] = otlp_body
                    sample["otlpAttributes"] = otlp_attributes
                print(json.dumps(sample), flush=True)
                print_message_variation(args, syslog_enabled, otlp_enabled)

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
        if syslog_connection is not None:
            syslog_connection.close()
        flushed = None
        export_succeeded = None
        if provider is not None:
            flushed = provider.force_flush(
                timeout_millis=args.timeout_seconds * 1000
            )
            provider.shutdown()
            export_succeeded = bool(exporter.export_results) and all(
                getattr(result, "name", "") == "SUCCESS"
                for result in exporter.export_results
            )

    summary = {
        "status": "stopped" if stop_requested else "completed",
        "runId": args.run_id,
        "protocol": args.protocol,
        "startedUtc": started_at,
        "stoppedUtc": utc_now(),
        "otlpFlushSucceeded": bool(flushed) if otlp_enabled else None,
        "otlpExportSucceeded": export_succeeded,
        "counts": counts,
    }
    print(json.dumps(summary), flush=True)
    return 0 if not otlp_enabled or (flushed and export_succeeded) else 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(json.dumps({"status": "failed", "error": str(error)}), file=sys.stderr)
        sys.exit(1)
