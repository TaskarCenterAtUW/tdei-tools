#!/usr/bin/env python3
"""Convert a GTFS archive's stops.txt into an OpenSidewalks 0.3 ZIP.

The ZIP contains exactly one file.  Both output names use the local calendar
date when the conversion starts:

    YYYY-MM-DD_GTFS_OSW.zip
      └── YYYY-MM-DD_GTFS_OSW.points.geojson

Only the standard library is required.

Usage examples:

    python utilities/gtfs_to_tdei_converter.py "C:/data/google_transit.zip"
    python utilities/gtfs_to_tdei_converter.py \
        "C:/data/google_transit.zip" -o "C:/data/output"

Valid parameters:

    input_zip             Required positional path to a GTFS ZIP archive.
    -o, --output-dir      Optional destination directory. Defaults to the
                          current directory. Created when it does not exist.

The input archive must contain a UTF-8 encoded ``stops.txt`` with the required
columns ``stop_id``, ``stop_lat``, and ``stop_lon``. The generated ZIP is named
``YYYY-MM-DD_GTFS_OSW.zip`` and contains one file named
``YYYY-MM-DD_GTFS_OSW.points.geojson``.
"""

from __future__ import annotations

import argparse
import csv
import io
import json
import math
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path


SCHEMA_URI = "https://sidewalks.washington.edu/opensidewalks/0.3/schema.json"
REQUIRED_FIELDS = ("stop_id", "stop_lat", "stop_lon")
STOPS_FILENAME = "stops.txt"


class ConversionError(Exception):
    """An expected input or conversion error."""


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Convert GTFS stops.txt to an OpenSidewalks 0.3 ZIP.",
        epilog=(
            "Examples:\n"
            '  python utilities/gtfs_to_tdei_converter.py '
            '"C:/data/google_transit.zip"\n'
            '  python utilities/gtfs_to_tdei_converter.py '
            '"C:/data/google_transit.zip" --output-dir "C:/data/output"\n\n'
            "Valid parameters:\n"
            "  input_zip       Required GTFS ZIP archive containing stops.txt.\n"
            "  -o, --output-dir\n"
            "                  Optional output directory; defaults to the "
            "current directory."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "input_zip",
        type=Path,
        help="GTFS ZIP archive containing stops.txt",
    )
    parser.add_argument(
        "-o",
        "--output-dir",
        type=Path,
        default=Path.cwd(),
        help="Directory for the generated ZIP (default: current directory)",
    )
    return parser.parse_args(argv)


def read_stops(input_zip: Path) -> list[dict[str, str]]:
    """Read and validate stops.txt from a GTFS ZIP archive."""
    if not input_zip.is_file():
        raise ConversionError(f"Input ZIP file not found: {input_zip}")

    try:
        with zipfile.ZipFile(input_zip) as archive:
            entry_name = next(
                (
                    info.filename
                    for info in archive.infolist()
                    if Path(info.filename).name.lower() == STOPS_FILENAME
                    and not info.is_dir()
                ),
                None,
            )
            if entry_name is None:
                raise ConversionError(
                    f"{STOPS_FILENAME} not found in ZIP archive"
                )
            raw_stops = archive.read(entry_name)
    except zipfile.BadZipFile as exc:
        raise ConversionError(f"Invalid ZIP archive: {input_zip}") from exc
    except OSError as exc:
        raise ConversionError(f"Could not read {input_zip}: {exc}") from exc

    try:
        text = raw_stops.decode("utf-8-sig")
    except UnicodeDecodeError as exc:
        raise ConversionError(
            f"{STOPS_FILENAME} must be UTF-8 encoded"
        ) from exc

    reader = csv.DictReader(io.StringIO(text, newline=""))
    if reader.fieldnames is None:
        raise ConversionError(f"{STOPS_FILENAME} is empty or has no header")

    fieldnames = [field.strip() for field in reader.fieldnames]
    missing = [field for field in REQUIRED_FIELDS if field not in fieldnames]
    if missing:
        raise ConversionError(
            f"Missing required GTFS fields in {STOPS_FILENAME}: "
            f"{', '.join(missing)}"
        )

    stops: list[dict[str, str]] = []
    for row_number, row in enumerate(reader, start=2):
        # Normalize header whitespace while retaining every source column.
        normalized = {
            (key.strip() if key is not None else ""): (value or "")
            for key, value in row.items()
        }
        if not any(value.strip() for value in normalized.values()):
            continue
        if None in row:
            raise ConversionError(
                f"Malformed row {row_number} in {STOPS_FILENAME}: "
                "too many columns"
            )
        stops.append(normalized)

    if not stops:
        raise ConversionError(f"{STOPS_FILENAME} is empty or contains no rows")
    return stops


def parse_coordinate(value: str, field: str, stop_id: str, limit: float) -> float:
    """Parse one finite coordinate and enforce its geographic range."""
    try:
        coordinate = float(value.strip())
    except (AttributeError, ValueError) as exc:
        raise ConversionError(
            f"Invalid {field} for stop {stop_id!r}: {value!r}."
        ) from exc
    if not math.isfinite(coordinate) or not -limit <= coordinate <= limit:
        raise ConversionError(
            f"Invalid {field} for stop {stop_id!r}: {value!r}. "
            f"Must be between {-limit:g} and {limit:g}."
        )
    return coordinate


def make_feature(stop: dict[str, str], feature_id: int) -> dict[str, object]:
    """Convert one GTFS stop to an OpenSidewalks CustomPoint feature."""
    stop_id = stop.get("stop_id", "").strip()
    if not stop_id:
        raise ConversionError("A stop is missing the required stop_id value")

    latitude = parse_coordinate(stop["stop_lat"], "latitude", stop_id, 90)
    longitude = parse_coordinate(stop["stop_lon"], "longitude", stop_id, 180)

    # CustomPointFields require _id.  GTFS fields are extension properties;
    # preserving them avoids inventing OpenSidewalks fields for transit data.
    properties: dict[str, object] = {"_id": str(feature_id)}
    for name, value in stop.items():
        if name:
            properties[f"ext:{name}"] = value

    return {
        "type": "Feature",
        "geometry": {
            "type": "Point",
            "coordinates": [longitude, latitude],
        },
        "properties": properties,
    }


def build_geojson(
    stops: list[dict[str, str]], input_zip: Path, timestamp: datetime
) -> dict[str, object]:
    """Build an OpenSidewalks 0.3 FeatureCollection."""
    return {
        "$schema": SCHEMA_URI,
        "type": "FeatureCollection",
        "features": [
            make_feature(stop, feature_id)
            for feature_id, stop in enumerate(stops, start=1)
        ],
        "dataTimestamp": timestamp.isoformat(timespec="milliseconds").replace(
            "+00:00", "Z"
        ),
        "dataSource": {
            "name": f"GTFS {STOPS_FILENAME} from {input_zip.name}",
            "timestamp": datetime.fromtimestamp(
                input_zip.stat().st_mtime, tz=timezone.utc
            )
            .isoformat(timespec="milliseconds")
            .replace("+00:00", "Z"),
        },
    }


def write_output(
    geojson: dict[str, object], output_dir: Path, date_stamp: str
) -> Path:
    """Write exactly one GeoJSON member into the dated ZIP."""
    output_dir.mkdir(parents=True, exist_ok=True)
    geojson_name = f"{date_stamp}_GTFS_OSW.points.geojson"
    zip_path = output_dir / f"{date_stamp}_GTFS_OSW.zip"
    temporary_zip_path = output_dir / f".{zip_path.name}.tmp"

    try:
        with zipfile.ZipFile(
            temporary_zip_path,
            mode="w",
            compression=zipfile.ZIP_DEFLATED,
            compresslevel=9,
        ) as archive:
            archive.writestr(
                geojson_name,
                json.dumps(geojson, ensure_ascii=False, indent=2) + "\n",
            )
        temporary_zip_path.replace(zip_path)
    except OSError as exc:
        temporary_zip_path.unlink(missing_ok=True)
        raise ConversionError(
            f"Could not create output ZIP {zip_path}: {exc}"
        ) from exc

    return zip_path


def convert(input_zip: Path, output_dir: Path, now: datetime | None = None) -> Path:
    """Convert an input GTFS archive and return the output ZIP path."""
    timestamp = now or datetime.now(timezone.utc)
    date_stamp = timestamp.astimezone().date().isoformat()
    stops = read_stops(input_zip)
    geojson = build_geojson(stops, input_zip, timestamp)
    return write_output(geojson, output_dir, date_stamp)


def main(argv: list[str] | None = None) -> int:
    """Run the command-line converter."""
    args = parse_args(argv)
    try:
        output_path = convert(args.input_zip, args.output_dir)
    except (ConversionError, OSError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    print(f"Success: created {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
