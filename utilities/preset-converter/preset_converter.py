#!/usr/bin/env python3
"""Convert common JOSM and Rapid (iD tagging schema) tagging presets."""

from __future__ import annotations

import argparse
import json
import re
import sys
import tempfile
import xml.etree.ElementTree as ET
from collections.abc import Iterable, Mapping
from pathlib import Path, PurePosixPath
from typing import Any, TypeGuard, cast

RAPID_GEOMETRIES: dict[str, tuple[str, ...]] = {
    "node": ("point", "vertex"),
    "way": ("line", "area"),
    "closedway": ("area",),
    "relation": ("relation",),
    "multipolygon": ("area",),
}
JOSM_GEOMETRIES: dict[str, tuple[str, ...]] = {
    "point": ("node",),
    "vertex": ("node",),
    "line": ("way",),
    "area": ("closedway", "multipolygon"),
    "relation": ("relation",),
}
TEXT_FIELD_TYPES = {
    "text",
    "number",
    "integer",
    "localized",
    "tel",
    "email",
    "url",
    "identifier",
    "colour",
    "schedule",
    "textarea",
    "date",
}


class ConversionError(ValueError):
    """Raised when an input cannot be safely converted."""


def _is_str_list(value: object) -> TypeGuard[list[str]]:
    if not isinstance(value, list):
        return False
    items = cast(list[Any], value)
    return all(isinstance(item, str) for item in items)


def _is_string_keyed_mapping(value: object) -> TypeGuard[Mapping[str, Any]]:
    if not isinstance(value, Mapping):
        return False
    mapping = cast(Mapping[Any, Any], value)
    return all(isinstance(key, str) for key in mapping)


def _is_string_mapping(value: object) -> TypeGuard[Mapping[str, str]]:
    if not isinstance(value, Mapping):
        return False
    mapping = cast(Mapping[Any, Any], value)
    return all(
        isinstance(key, str) and isinstance(item, str)
        for key, item in mapping.items()
    )


def _split(value: str | None, delimiter: str = ",") -> list[str]:
    if not value:
        return []
    if not delimiter:
        return [value.strip()]
    parts: list[str] = []
    current: list[str] = []
    index = 0
    while index < len(value):
        character = value[index]
        if character == "\\":
            next_index = index + 1
            if value.startswith(delimiter, next_index):
                current.append(delimiter)
                index += len(delimiter) + 1
                continue
            if next_index < len(value) and value[next_index] == "\\":
                current.append("\\")
                index += 2
                continue
            current.append("\\")
        elif value.startswith(delimiter, index):
            parts.append("".join(current).strip())
            current.clear()
            index += len(delimiter)
            continue
        else:
            current.append(character)
        index += 1
    parts.append("".join(current).strip())
    return parts


def _join(values: Iterable[str], delimiter: str) -> str:
    escaped_values = (
        value.replace("\\", "\\\\").replace(delimiter, f"\\{delimiter}")
        for value in values
    )
    return delimiter.join(escaped_values)


def _slug(value: str) -> str:
    result = re.sub(r"[^a-z0-9]+", "_", value.casefold()).strip("_")
    return result or "preset"


def _unique(values: Iterable[str]) -> list[str]:
    return list(dict.fromkeys(value for value in values if value))


def _safe_preset_path(identifier: str) -> PurePosixPath:
    path = PurePosixPath(identifier)
    if path.is_absolute() or ".." in path.parts or not path.parts:
        raise ConversionError(f"unsafe preset identifier: {identifier!r}")
    if any(not re.fullmatch(r"[A-Za-z0-9_.@-]+", part) for part in path.parts):
        raise ConversionError(
            f"unsupported characters in preset identifier: {identifier!r}")
    return path


def _strip_namespace(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def _field_id(key: str, element: ET.Element) -> str:
    hint = element.get("id")
    if hint and re.fullmatch(r"[A-Za-z0-9_.-]+", hint):
        return hint
    path = key.split(":")
    if key.endswith(":"):
        path[-1] = path[-1].removesuffix(":") or "values"
    return "/".join(path)


def _option_labels(
    element: Mapping[str, Any] | ET.Element, element_type: str | None = None
) -> tuple[list[str], dict[str, str]]:
    get = element.get
    if isinstance(element, ET.Element):
        element_type = _strip_namespace(element.tag)
        entries: Iterable[ET.Element] = element
    else:
        entries = ()
    delimiter = get("delimiter")
    if not isinstance(delimiter, str) or not delimiter:
        delimiter = ";" if element_type == "multiselect" else ","
    values = _split(get("values") if isinstance(
        get("values"), str) else None, delimiter)
    labels = _split(get("display_values") if isinstance(
        get("display_values"), str) else None, delimiter)
    options: dict[str, str] = {}
    for index, value in enumerate(values):
        if index < len(labels) and labels[index] and labels[index] != value:
            options[value] = labels[index]
    if not values and labels:
        values = labels.copy()
    for entry in entries:
        if _strip_namespace(entry.tag) == "list_entry":
            value = entry.get("value")
            display = entry.get("display_value")
            if value and display and display != value:
                options[value] = display
            if value and value not in values:
                values.append(value)
    return values, options


def _rapid_options(field: Mapping[str, Any]) -> tuple[list[str], dict[str, str]]:
    options = field.get("options")
    string_options: Mapping[str, Any] | None = None
    strings = field.get("strings")
    if _is_string_keyed_mapping(strings):
        candidate = strings.get("options")
        if _is_string_mapping(candidate):
            string_options = candidate
    if _is_str_list(options):
        values = options
    elif string_options is not None:
        values = list(string_options)
    else:
        values = []
    labels: dict[str, str] = {}
    if string_options is not None:
        for value in values:
            label = string_options.get(value, value)
            if isinstance(label, str) and label != value:
                labels[value] = label
    return values, labels


def _field_reference(
    field: Mapping[str, Any], hint: str | None = None
) -> tuple[str, dict[str, Any]] | None:
    """Validate and preserve a referenced Rapid field definition."""
    kind = field.get("type")
    key = field.get("key")
    if not isinstance(kind, str):
        return None

    if kind == "address":
        if not isinstance(key, str) or not key:
            key = "addr"
        keys = field.get("keys")
        if not _is_str_list(keys) or not all(keys):
            return None
        return _field_id(key, ET.Element("text", {"id": hint} if hint else {})), {
            "key": key,
            "type": kind,
            "label": field.get("label", "Address"),
            "keys": keys,
        }

    if not isinstance(key, str) or not key:
        return None
    identifier = _field_id(key, ET.Element(
        "text", {"id": hint} if hint else {}))
    label = field.get("label")
    if not isinstance(label, str):
        label = key
    converted: dict[str, Any] = {"key": key, "type": kind, "label": label}
    if isinstance(field.get("default"), str) and field["default"]:
        converted["default"] = field["default"]

    if kind in {"combo", "typeCombo", "semiCombo", "radio"}:
        values, labels = _rapid_options(field)
        if not values:
            return None
        if isinstance(field.get("options"), list):
            converted["options"] = values
        if labels:
            converted["strings"] = {"options": labels}
        if kind in {"combo", "typeCombo", "radio"} and field.get("customValues") is False:
            converted["customValues"] = False
    elif kind == "multiCombo":
        values, labels = _rapid_options(field)
        if values:
            converted["options"] = values
        if labels:
            converted["strings"] = {"options": labels}
    elif kind in {"check", "defaultCheck"}:
        options = field.get("options")
        if options is not None and (
            not _is_str_list(options) or "yes" not in options
        ):
            return None
        if _is_str_list(options):
            converted["options"] = options
    elif kind in TEXT_FIELD_TYPES:
        pass
    elif kind != "access":
        return None
    return identifier, converted


def _rapid_field_definition(
    field: Mapping[str, Any] | ET.Element, element_type: str
) -> dict[str, Any] | None:
    """Convert the supported JOSM field subset into a Rapid field definition."""
    attributes = field.attrib if isinstance(field, ET.Element) else field
    key = attributes.get("key")
    label = attributes.get("text") or key
    if not isinstance(key, str) or not key or not isinstance(label, str):
        return None
    if element_type == "text":
        kind = "text"
        values: list[str] = []
        labels: dict[str, str] = {}
    elif element_type == "check":
        kind = "check"
        values, labels = [], {}
    elif element_type == "combo":
        kind = "combo"
        values, labels = _option_labels(field, element_type)
        if not values:
            return None
    elif element_type == "multiselect":
        values, labels = _option_labels(field, element_type)
        delimiter = attributes.get("delimiter", ";")
        if not values or delimiter != ";":
            return None
        kind = "semiCombo"
    else:
        return None

    result: dict[str, Any] = {"key": key, "type": kind, "label": label}
    default = attributes.get("default")
    if isinstance(default, str) and default:
        if element_type == "check":
            if default == "on":
                result["default"] = "yes"
            elif default == "off":
                result["options"] = ["undefined", "yes", "no"]
                result["default"] = "no"
            else:
                return None
        else:
            result["default"] = default
    if element_type in {"combo", "multiselect"}:
        if labels:
            result["strings"] = {"options": labels}
        if kind == "combo" and attributes.get("editable") == "false":
            result["customValues"] = False
        if kind in {"combo", "semiCombo"}:
            result["options"] = values
    if element_type == "check":
        value_on = attributes.get("value_on", "yes")
        if value_on != "yes":
            return None
        value_off = attributes.get("value_off")
        disable_off = attributes.get("disable_off") == "true"
        if value_off is None and not disable_off:
            return None
        result["type"] = "defaultCheck" if disable_off else "check"
        if not disable_off:
            if value_off != "no":
                return None
            result["options"] = ["undefined", "yes", "no"]
    return result


def _preset_items(root: ET.Element) -> list[tuple[ET.Element, tuple[str, ...]]]:
    items: list[tuple[ET.Element, tuple[str, ...]]] = []

    def walk(parent: ET.Element, groups: tuple[str, ...] = ()) -> None:
        for child in parent:
            name = _strip_namespace(child.tag)
            if name == "group":
                group_name = child.get("name", "").strip()
                nested_groups = groups + ((group_name,) if group_name else ())
                walk(child, nested_groups)
            elif name == "item":
                items.append((child, groups))

    walk(root)
    return items


def _josm_item_to_rapid(
    item: ET.Element,
    identifier: str,
    warnings: list[str],
    groups: tuple[str, ...] = (),
) -> tuple[dict[str, Any] | None, dict[str, dict[str, Any]]]:
    tags: dict[str, str] = {}
    field_ids: list[str] = []
    field_definitions: dict[str, dict[str, Any]] = {}
    optional_ids: list[str] = []
    optional_definitions: dict[str, dict[str, Any]] = {}
    seen_keys: set[str] = set()
    for element in item.iter():
        if _strip_namespace(element.tag) == "key":
            key = element.get("key")
            if key:
                seen_keys.add(key)
    tag_elements = {"key"}
    input_elements = {"text", "combo", "multiselect", "check"}

    def add_field(element: ET.Element, optional: bool = False) -> None:
        key = element.get("key")
        if not key:
            warnings.append(
                f"{identifier}: <{_strip_namespace(element.tag)}> has no key")
            return
        if key in seen_keys:
            warnings.append(
                f"{identifier}: duplicate field for key {key!r}; kept the first")
            return
        converted = _rapid_field_definition(
            element, _strip_namespace(element.tag))
        if converted is None:
            if _strip_namespace(element.tag) == "multiselect":
                warnings.append(
                    f"{identifier}: <multiselect> for key {key!r} requires static semicolon-delimited values"
                )
            else:
                warnings.append(
                    f"{identifier}: unsupported <{_strip_namespace(element.tag)}> for key {key!r}")
            return
        seen_keys.add(key)
        field_identifier = _field_id(key, element)
        destination = optional_definitions if optional else field_definitions
        field_list = optional_ids if optional else field_ids
        base_identifier = field_identifier
        existing_definition = field_definitions.get(
            field_identifier) or optional_definitions.get(field_identifier)
        suffix = 2
        while existing_definition is not None and existing_definition != converted:
            field_identifier = f"{base_identifier}_{_slug(key)}" if suffix == 2 else f"{base_identifier}_{suffix}"
            existing_definition = field_definitions.get(
                field_identifier) or optional_definitions.get(field_identifier)
            suffix += 1
        destination[field_identifier] = converted
        field_list.append(field_identifier)

    def walk(parent: ET.Element, optional: bool = False) -> None:
        for element in parent:
            name = _strip_namespace(element.tag)
            if name == "optional" or name == "optional_attributes":
                walk(element, True)
            elif name in tag_elements:
                key = element.get("key")
                value = element.get("value")
                if key and value is None:
                    warnings.append(
                        f"{identifier}: skipped tag removal for {key!r}")
                elif key and value == "":
                    warnings.append(
                        f"{identifier}: skipped fixed tag {key!r} with an empty value")
                elif key and value is not None:
                    if key in tags:
                        if tags[key] != value:
                            warnings.append(
                                f"{identifier}: conflicting fixed tag {key!r}; kept the first")
                    else:
                        tags[key] = value
            elif name in input_elements:
                add_field(element, optional)
            elif name not in {"label", "space", "separator"}:
                warnings.append(f"{identifier}: skipped unsupported <{name}>")

    walk(item)
    geometries: list[str] = []
    item_type = item.get("type")
    for geometry in _split(item_type):
        mapped = RAPID_GEOMETRIES.get(geometry)
        if mapped:
            for rapid_geometry in mapped:
                if rapid_geometry not in geometries:
                    geometries.append(rapid_geometry)
        elif not mapped:
            warnings.append(
                f"{identifier}: skipped unsupported JOSM geometry {geometry!r}")
    if not geometries:
        if item_type and item_type.strip():
            warnings.append(
                f"{identifier}: preset has no supported geometry; skipped")
            return None, {}
        geometries = ["point", "vertex", "line", "area", "relation"]
    preset: dict[str, Any] = {
        "name": item.get("name") or identifier.rsplit("/", 1)[-1],
        "geometry": geometries,
        "tags": tags,
    }
    if field_ids:
        preset["fields"] = field_ids
    if optional_ids:
        preset["moreFields"] = optional_ids
    if groups:
        preset["terms"] = list(groups)
    if item.get("icon"):
        preset["icon"] = item.get("icon")
    return preset, field_definitions | optional_definitions


def convert_josm_to_rapid(
    source: Path, output_dir: Path, overwrite: bool = False, preset_id: str | None = None
) -> tuple[list[Path], list[str]]:
    """Convert JOSM items into a Rapid preset and reusable field files."""
    try:
        tree = ET.parse(source)
    except (ET.ParseError, OSError) as exc:
        raise ConversionError(f"cannot read JOSM XML {source}: {exc}") from exc
    root = tree.getroot()
    if _strip_namespace(root.tag) != "presets":
        raise ConversionError("JOSM input root element must be <presets>")
    items = _preset_items(root)
    if not items:
        raise ConversionError("JOSM file contains no <item> presets")
    base_id = _safe_preset_path(preset_id or _slug(source.stem))
    warnings: list[str] = []
    presets: dict[str, dict[str, Any]] = {}
    fields: dict[str, dict[str, Any]] = {}
    for index, (item, groups) in enumerate(items, start=1):
        name = item.get("name") or f"Preset {index}"
        suffix = _slug(name)
        base_identifier = f"{base_id}/{suffix}"
        identifier = base_identifier
        if identifier in presets:
            identifier = f"{base_identifier}_{index}"
            collision_index = 2
            while identifier in presets:
                identifier = f"{base_identifier}_{index}_{collision_index}"
                collision_index += 1
            warnings.append(
                f"{base_identifier}: preset ID collision; wrote {identifier!r}")
        preset, definitions = _josm_item_to_rapid(
            item, identifier, warnings, groups)
        if preset is None:
            continue
        presets[identifier] = preset
        renamed_fields: dict[str, str] = {}
        for field_id, definition in definitions.items():
            stored_id = field_id
            suffix = 2
            while stored_id in fields and fields[stored_id] != definition:
                if stored_id == field_id:
                    stored_id = f"{field_id}_{_slug(str(definition.get('key', 'field')))}"
                else:
                    stored_id = f"{field_id}_{suffix}"
                    suffix += 1
            if stored_id != field_id:
                renamed_fields[field_id] = stored_id
                warnings.append(
                    f"{identifier}: field ID collision; wrote {stored_id!r}")
            fields[stored_id] = definition
        for list_name in ("fields", "moreFields"):
            references = preset.get(list_name)
            if _is_str_list(references):
                preset[list_name] = [
                    renamed_fields.get(reference, reference)
                    for reference in references
                ]

    if not presets:
        raise ConversionError("no convertible JOSM presets found")

    output_files: dict[Path, dict[str, Any]] = {}
    for identifier, preset in presets.items():
        relative = _safe_preset_path(identifier)
        path = output_dir / "data" / "presets" / Path(
            *relative.parts[:-1], f"{relative.name}.json"
        )
        output_files[path] = preset
    for identifier, definition in fields.items():
        relative = _safe_preset_path(identifier)
        path = output_dir / "data" / "fields" / Path(
            *relative.parts[:-1], f"{relative.name}.json"
        )
        if path in output_files and output_files[path] != definition:
            raise ConversionError(
                f"preset and field IDs collide at output path: {path}")
        output_files[path] = definition
    if not overwrite:
        existing = [path for path in output_files if path.exists()]
        if existing:
            raise ConversionError(
                "output files already exist (use --overwrite to replace them): "
                + ", ".join(str(path) for path in existing)
            )
    return _write_json_files(output_files, overwrite), warnings


def _load_json(path: Path) -> Any:
    try:
        with path.open(encoding="utf-8") as stream:
            return json.load(stream)
    except (OSError, json.JSONDecodeError) as exc:
        raise ConversionError(f"cannot read JSON {path}: {exc}") from exc


def _discover_presets(source: Path) -> list[tuple[str, dict[str, Any]]]:
    if source.is_file():
        data = _load_json(source)
        if not _is_string_keyed_mapping(data):
            raise ConversionError(f"preset JSON must be an object: {source}")
        return [(source.stem, dict(data))]
    if (source / "data" / "presets").is_dir():
        presets_dir = source / "data" / "presets"
    elif source.name.casefold() == "data":
        presets_dir = source / "presets"
    else:
        presets_dir = source
    if not presets_dir.is_dir():
        raise ConversionError(
            f"Rapid input must be a preset JSON file or directory: {source}")
    result: list[tuple[str, dict[str, Any]]] = []
    for path in sorted(presets_dir.rglob("*.json")):
        relative = path.relative_to(presets_dir).with_suffix("")
        if any(part.startswith("_") or part == "@templates" for part in relative.parts):
            continue
        data = _load_json(path)
        if _is_string_keyed_mapping(data):
            result.append((relative.as_posix(), dict(data)))
    return result


def _load_rapid_fields(source: Path, *, allow_direct: bool = False) -> dict[str, dict[str, Any]]:
    base = source if source.is_dir() else source.parent
    field_dir: Path | None = None
    for directory in (base, *base.parents):
        if directory.name == "fields":
            field_dir = directory
        elif directory.name == "data" and (directory / "fields").is_dir():
            field_dir = directory / "fields"
        elif directory.name == "presets" and (directory.parent / "fields").is_dir():
            field_dir = directory.parent / "fields"
        elif (directory / "data" / "fields").is_dir():
            field_dir = directory / "data" / "fields"
        if field_dir is not None:
            break
    if field_dir is None and allow_direct:
        field_dir = source if source.is_dir() else source.parent
    fields: dict[str, dict[str, Any]] = {}
    if field_dir is None or not field_dir.is_dir():
        return fields
    for path in sorted(field_dir.rglob("*.json")):
        relative = path.relative_to(field_dir).with_suffix("").as_posix()
        data = _load_json(path)
        if _is_string_keyed_mapping(data):
            fields[relative] = dict(data)
    return fields


def _expand_field_reference(
    reference: str,
    fields: Mapping[str, dict[str, Any]],
    warnings: list[str],
    preset_id: str,
) -> list[tuple[str, dict[str, Any]]]:
    normalized = reference.strip().strip("{}")
    if normalized.startswith("data/fields/"):
        normalized = normalized.removeprefix("data/fields/")
    elif normalized.startswith("fields/"):
        normalized = normalized.removeprefix("fields/")
    if normalized.startswith("presets/") or normalized.startswith("data/presets/"):
        warnings.append(
            f"{preset_id}: skipped referenced preset field {reference!r}")
        return []
    if normalized in fields:
        identifiers = [normalized]
    else:
        basename = PurePosixPath(normalized).name
        identifiers = [
            identifier for identifier in fields if PurePosixPath(identifier).stem == basename
        ]
    if len(identifiers) > 1:
        warnings.append(
            f"{preset_id}: ambiguous field reference {reference!r}; skipped")
        return []
    if not identifiers:
        warnings.append(
            f"{preset_id}: unresolved field reference {reference!r}; skipped")
        return []
    identifier = identifiers[0]
    converted = _field_reference(
        fields[identifier], PurePosixPath(identifier).name)
    if converted is None:
        warnings.append(
            f"{preset_id}: unsupported field definition {reference!r}; skipped")
        return []
    return [converted]


def _rapid_item_to_josm(
    identifier: str,
    preset: Mapping[str, Any],
    fields: Mapping[str, dict[str, Any]],
    warnings: list[str],
    index: int,
) -> ET.Element | None:
    tags_value = preset.get("tags")
    if not _is_string_keyed_mapping(tags_value):
        warnings.append(f"{identifier}: skipped preset without a tags object")
        return None
    if any(
        not isinstance(value, str) or not key or not value
        for key, value in tags_value.items()
    ):
        warnings.append(f"{identifier}: skipped preset with invalid tags")
        return None
    tags = cast(Mapping[str, str], tags_value)
    name = preset.get("name")
    if not isinstance(name, str) or not name:
        name = identifier.rsplit("/", 1)[-1].replace("_", " ").title()
        warnings.append(f"{identifier}: generated a display name")
    element = ET.Element("item", {"name": name})
    geometry_value = preset.get("geometry", [])
    if not _is_str_list(geometry_value):
        warnings.append(f"{identifier}: ignored invalid geometry")
        geometry: list[str] = []
    else:
        geometry = geometry_value
    if not geometry:
        warnings.append(f"{identifier}: preset has no supported geometry")
        return None
    for kind in geometry:
        if kind not in JOSM_GEOMETRIES:
            warnings.append(
                f"{identifier}: skipped unsupported Rapid geometry {kind!r}")
    if isinstance(preset.get("icon"), str):
        element.set("icon", preset["icon"])
    for key, value in tags.items():
        ET.SubElement(element, "key", {"key": key, "value": value})

    preset_types: list[str] = []
    for rapid_geometry in geometry:
        if rapid_geometry in {"point", "vertex"}:
            preset_types.append("node")
        elif rapid_geometry == "line":
            preset_types.append("way")
        elif rapid_geometry == "area":
            preset_types.extend(("closedway", "multipolygon"))
        elif rapid_geometry == "relation":
            preset_types.append("relation")
    if not preset_types:
        warnings.append(
            f"{identifier}: preset has no supported geometry; skipped")
        return None
    element.set("type", ",".join(_unique(preset_types)))

    seen_keys: set[str] = set(tags)
    for list_name in ("fields", "moreFields"):
        references_value = preset.get(list_name, [])
        if not isinstance(references_value, list):
            warnings.append(f"{identifier}: ignored invalid {list_name}")
            continue
        references = cast(list[Any], references_value)
        parent = element
        if list_name == "moreFields" and references:
            parent = ET.SubElement(element, "optional")
        for reference in references:
            if not isinstance(reference, str):
                warnings.append(
                    f"{identifier}: ignored invalid field reference {reference!r}")
                continue
            for _, field in _expand_field_reference(reference, fields, warnings, identifier):
                key = field.get("key")
                if not isinstance(key, str):
                    continue
                if key in seen_keys:
                    warnings.append(
                        f"{identifier}: skipped duplicate field for fixed tag {key!r}")
                    continue
                field_type = field.get("type")
                attributes = {"key": key, "text": str(field.get("label", key))}
                if isinstance(field.get("default"), str):
                    attributes["default"] = field["default"]
                if field_type == "check" or field_type == "defaultCheck":
                    if field.get("options"):
                        options = field["options"]
                        on_values = [
                            option for option in options if option not in {"undefined", "no"}]
                        off_values = [
                            option for option in options if option not in {"undefined", "yes"}]
                        if len(on_values) != 1 or len(off_values) > 1:
                            warnings.append(
                                f"{identifier}: check field {key!r} has unsupported values; skipped")
                            continue
                        attributes["value_on"] = on_values[0]
                        if off_values:
                            attributes["value_off"] = off_values[0]
                        else:
                            attributes["disable_off"] = "true"
                    if field_type == "defaultCheck":
                        attributes.setdefault("disable_off", "true")
                        attributes["default"] = "on"
                    else:
                        attributes.setdefault("value_on", "yes")
                        attributes.setdefault("value_off", "no")
                    ET.SubElement(parent, "check", attributes)
                    seen_keys.add(key)
                elif field_type in TEXT_FIELD_TYPES:
                    ET.SubElement(parent, "text", attributes)
                    seen_keys.add(key)
                elif field_type in {"combo", "radio", "typeCombo"}:
                    values, labels = _rapid_options(field)
                    if not values:
                        warnings.append(
                            f"{identifier}: combo field {key!r} has no static options; skipped")
                        continue
                    attributes["values"] = _join(values, ",")
                    display_values = [labels.get(value, value)
                                      for value in values]
                    if display_values != values:
                        attributes["display_values"] = _join(
                            display_values, ",")
                    if field.get("customValues") is False:
                        attributes["editable"] = "false"
                    ET.SubElement(parent, "combo", attributes)
                    seen_keys.add(key)
                elif field_type == "semiCombo":
                    values, labels = _rapid_options(field)
                    if not values:
                        warnings.append(
                            f"{identifier}: semiCombo field {key!r} has no static options; skipped")
                        continue
                    attributes["values"] = _join(values, ";")
                    attributes["delimiter"] = ";"
                    display_values = [labels.get(value, value)
                                      for value in values]
                    if display_values != values:
                        attributes["display_values"] = _join(
                            display_values, ";")
                    ET.SubElement(parent, "multiselect", attributes)
                    seen_keys.add(key)
                elif field_type == "multiCombo":
                    warnings.append(
                        f"{identifier}: multiCombo field {key!r} was skipped because JOSM multiselect cannot represent independent yes/no subtags")
                elif field_type == "address":
                    keys = field.get("keys")
                    if not _is_str_list(keys):
                        warnings.append(
                            f"{identifier}: address field {key!r} has no supported subkeys; skipped")
                        continue
                    for address_key in keys:
                        if address_key not in seen_keys:
                            ET.SubElement(parent, "text", {"key": address_key, "text": address_key.removeprefix(
                                f"{key}:").replace("_", " ").title()})
                            seen_keys.add(address_key)
                else:
                    warnings.append(
                        f"{identifier}: skipped unsupported Rapid field type {field_type!r} ({key})")

    return element


def convert_rapid_to_josm(
    source: Path,
    output: Path,
    overwrite: bool = False,
    fields_dir: Path | None = None,
) -> tuple[list[Path], list[str]]:
    """Convert Rapid preset JSON (file, directory, or checkout) to JOSM XML."""
    presets = _discover_presets(source)
    if not presets:
        raise ConversionError(f"no Rapid preset JSON files found in {source}")
    field_source = fields_dir or (source if source.is_dir() else source.parent)
    fields = _load_rapid_fields(
        field_source, allow_direct=fields_dir is not None)
    root = ET.Element(
        "presets", {"xmlns": "http://josm.openstreetmap.de/tagging-preset-1.0"})
    warnings: list[str] = []
    seen_names: set[str] = set()
    for index, (identifier, preset) in enumerate(presets, start=1):
        element = _rapid_item_to_josm(
            identifier, preset, fields, warnings, index)
        if element is None:
            continue
        name = element.get("name", "")
        if name in seen_names:
            unique_name = f"{name} ({index})"
            while unique_name in seen_names:
                unique_name = f"{unique_name} ({index})"
            element.set("name", unique_name)
            warnings.append(
                f"{identifier}: disambiguated duplicate preset name {name!r}")
        seen_names.add(element.get("name", ""))
        root.append(element)
    if len(root) == 0:
        raise ConversionError("no convertible Rapid presets found")
    ET.indent(root, space="  ")
    payload = ET.tostring(root, encoding="utf-8", xml_declaration=True) + b"\n"
    _write_bytes_file(output, payload, overwrite)
    return [output], warnings


def _write_json_files(files: Mapping[Path, dict[str, Any]], overwrite: bool) -> list[Path]:
    payloads = {
        path: (json.dumps(data, ensure_ascii=False,
               indent=2) + "\n").encode("utf-8")
        for path, data in files.items()
    }
    return _write_files(payloads, overwrite)


def _write_files(files: Mapping[Path, bytes], overwrite: bool) -> list[Path]:
    destinations = sorted(files)
    existing = [path for path in destinations if path.exists()]
    if existing and not overwrite:
        raise ConversionError(
            "output files already exist (use --overwrite to replace them): "
            + ", ".join(str(path) for path in existing)
        )

    staged: dict[Path, Path] = {}
    backups: dict[Path, bytes] = {}
    try:
        for path in destinations:
            path.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(
                mode="wb", prefix=f".{path.name}.", suffix=".tmp", dir=path.parent, delete=False
            ) as stream:
                stream.write(files[path])
                staged[path] = Path(stream.name)
        if overwrite:
            for path in existing:
                backups[path] = path.read_bytes()
        committed: list[Path] = []
        for path in destinations:
            staged[path].replace(path)
            committed.append(path)
        return destinations
    except OSError as exc:
        for path in reversed(locals().get("committed", [])):
            if path in backups:
                path.write_bytes(backups[path])
            else:
                path.unlink(missing_ok=True)
        raise ConversionError(f"cannot write generated output: {exc}") from exc
    finally:
        for temporary in staged.values():
            temporary.unlink(missing_ok=True)


def _write_bytes_file(path: Path, payload: bytes, overwrite: bool) -> None:
    _write_files({path: payload}, overwrite)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Convert common JOSM XML and Rapid (id-tagging-schema) JSON presets.",
        epilog=(
            "Supports fixed tags, common field widgets, nested groups, optional fields, "
            "static options, and common geometry types. Unsupported features are skipped with warnings."
        ),
    )
    subparsers = parser.add_subparsers(dest="direction", required=True)
    josm_parser = subparsers.add_parser(
        "josm-to-rapid", help="Convert JOSM XML to Rapid JSON files")
    josm_parser.add_argument("input", type=Path, help="JOSM preset XML file")
    josm_parser.add_argument(
        "output_dir", type=Path, help="Output directory (writes data/presets and data/fields)")
    josm_parser.add_argument(
        "--preset-id", help="Base Rapid preset ID, e.g. transport/accessmap")
    josm_parser.add_argument("--overwrite", action="store_true",
                             help="Replace generated files that already exist")
    rapid_parser = subparsers.add_parser(
        "rapid-to-josm", help="Convert Rapid JSON presets to JOSM XML")
    rapid_parser.add_argument(
        "input", type=Path, help="Rapid preset JSON file, data directory, or repository checkout")
    rapid_parser.add_argument("output", type=Path, help="Output JOSM XML file")
    rapid_parser.add_argument(
        "--fields-dir", type=Path, help="Directory containing Rapid data/fields JSON files")
    rapid_parser.add_argument("--overwrite", action="store_true",
                              help="Replace the output XML file if it exists")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.direction == "josm-to-rapid":
            paths, warnings = convert_josm_to_rapid(
                args.input, args.output_dir, args.overwrite, args.preset_id)
        else:
            paths, warnings = convert_rapid_to_josm(
                args.input, args.output, args.overwrite, args.fields_dir)
    except ConversionError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    print(f"Wrote {len(paths)} file(s):")
    for path in paths:
        print(f"  {path}")
    for warning in warnings:
        print(f"warning: {warning}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
