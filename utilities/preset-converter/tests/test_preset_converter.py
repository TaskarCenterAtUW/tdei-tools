from __future__ import annotations

import importlib.util
import json
import sys
from typing import Any
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest

MODULE_PATH = Path(__file__).resolve().parents[1] / "preset_converter.py"
SPEC = importlib.util.spec_from_file_location("preset_converter", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
converter = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = converter
SPEC.loader.exec_module(converter)

FIXTURES = Path(__file__).parent / "fixtures"
JOSM_FIXTURE = FIXTURES / "josm-presets.xml"
RAPID_FIXTURE = FIXTURES / "rapid"


def test_josm_to_rapid_creates_presets_and_reusable_fields(tmp_path: Path) -> None:
    output = tmp_path / "rapid"
    paths, warnings = converter.convert_josm_to_rapid(JOSM_FIXTURE, output)

    preset = json.loads(
        (output / "data/presets/josm_presets/cafe.json").read_text(encoding="utf-8"))
    assert preset == {
        "name": "Cafe",
        "geometry": ["point", "vertex", "area"],
        "tags": {"amenity": "cafe"},
        "fields": ["name", "cuisine", "diet", "outdoor_seating"],
        "moreFields": ["phone"],
        "terms": ["Food and drink"],
        "icon": "cafe.png",
    }
    assert json.loads((output / "data/fields/cuisine.json").read_text(encoding="utf-8")) == {
        "key": "cuisine",
        "type": "combo",
        "label": "Cuisine",
        "strings": {"options": {"italian": "Italian", "coffee_shop": "Coffee shop"}},
        "options": ["italian", "coffee_shop"],
    }
    assert json.loads((output / "data/fields/diet.json").read_text(encoding="utf-8")) == {
        "key": "diet",
        "type": "semiCombo",
        "label": "Dietary options",
        "strings": {"options": {"vegetarian": "Vegetarian", "vegan": "Vegan"}},
        "options": ["vegetarian", "vegan"],
    }
    bakery = json.loads(
        (output / "data/presets/josm_presets/bakery.json").read_text(encoding="utf-8")
    )
    assert bakery["tags"] == {"shop": "bakery"}
    assert "fields" not in bakery
    assert len(paths) == 7
    assert any("duplicate field for key 'shop'" in warning for warning in warnings)


def test_rapid_to_josm_resolves_fields_and_preserves_widgets(tmp_path: Path) -> None:
    output = tmp_path / "converted.xml"
    paths, warnings = converter.convert_rapid_to_josm(RAPID_FIXTURE, output)

    root = ET.parse(output).getroot()
    ns = {"josm": "http://josm.openstreetmap.de/tagging-preset-1.0"}
    item = root.find("josm:item", ns)
    assert item is not None
    assert item.attrib == {
        "name": "Cafe",
        "type": "node,closedway,multipolygon",
        "icon": "cafe",
    }
    fixed = item.find("josm:key", ns)
    assert fixed is not None and fixed.attrib == {
        "key": "amenity", "value": "cafe"}
    fields = item.findall("josm:text", ns)
    assert fields[0].attrib == {"key": "name",
                                "text": "Name", "default": "Coffee shop"}
    optional = item.find("josm:optional", ns)
    assert optional is not None
    phone = optional.find("josm:text", ns)
    assert phone is not None
    assert phone.attrib == {"key": "phone", "text": "Phone"}
    combo = item.find("josm:combo", ns)
    assert combo is not None
    assert combo.get("values") == "italian,coffee_shop"
    assert combo.get("display_values") == "Italian,Coffee shop"
    multi_select_fields = item.findall("josm:multiselect", ns)
    assert len(multi_select_fields) == 1
    multi_select = multi_select_fields[0]
    assert multi_select.get("key") == "diet"
    assert multi_select.get("values") == "vegetarian;vegan"
    assert multi_select.get("display_values") == "Vegetarian;Vegan"
    assert multi_select.get("delimiter") == ";"
    assert item.find("josm:check", ns) is not None
    assert len(paths) == 1
    assert any(
        "multiCombo field 'diet:' was skipped" in warning for warning in warnings)
    assert any(
        "unresolved field reference 'not_here'" in warning for warning in warnings)


def test_rapid_field_references_resolve_nested_paths_and_reject_ambiguity(tmp_path: Path) -> None:
    fields: dict[str, Any] = {
        "fields": {
            "addr/housenumber": {"key": "addr:housenumber", "type": "text", "label": "House number"},
            "transport/road/surface": {"key": "surface", "type": "text", "label": "Surface"},
        },
        "warnings": [],
    }
    nested = converter._expand_field_reference(
        "{addr/housenumber}", fields["fields"], fields["warnings"], "roads"
    )
    basename = converter._expand_field_reference(
        "surface", fields["fields"], fields["warnings"], "roads"
    )

    assert nested[0][1]["key"] == "addr:housenumber"
    assert basename[0][1]["key"] == "surface"
    assert not fields["warnings"]

    fields["fields"]["indoor/surface"] = {
        "key": "indoor:surface",
        "type": "text",
        "label": "Indoor surface",
    }
    assert converter._expand_field_reference(
        "surface", fields["fields"], fields["warnings"], "roads"
    ) == []
    assert any(
        "ambiguous field reference 'surface'" in warning for warning in fields["warnings"])


def test_rapid_multi_combo_is_skipped_with_explanation(tmp_path: Path) -> None:
    output = tmp_path / "converted.xml"
    _, warnings = converter.convert_rapid_to_josm(RAPID_FIXTURE, output)
    root = ET.parse(output).getroot()
    ns = {"josm": "http://josm.openstreetmap.de/tagging-preset-1.0"}
    cafe = next(item for item in root.findall(
        "josm:item", ns) if item.get("name") == "Cafe")

    assert cafe.find("josm:multiselect[@key='diet:']", ns) is None
    assert any(
        "multiCombo field 'diet:' was skipped" in warning for warning in warnings)


def test_rapid_multi_combo_without_options_is_skipped_with_explanation(tmp_path: Path) -> None:
    source = tmp_path / "data" / "presets" / "food" / "restaurant.json"
    fields_dir = tmp_path / "data" / "fields"
    source.parent.mkdir(parents=True)
    fields_dir.mkdir(parents=True)
    source.write_text(
        json.dumps({"name": "Restaurant", "geometry": ["point"], "tags": {
                   "amenity": "restaurant"}, "fields": ["diet"]}),
        encoding="utf-8",
    )
    (fields_dir / "diet.json").write_text(
        json.dumps({"key": "diet:", "type": "multiCombo",
                   "label": "Dietary options"}),
        encoding="utf-8",
    )

    output = tmp_path / "restaurant.xml"
    _, warnings = converter.convert_rapid_to_josm(source, output)
    root = ET.parse(output).getroot()
    ns = {"josm": "http://josm.openstreetmap.de/tagging-preset-1.0"}
    restaurant = root.find("josm:item", ns)

    assert restaurant is not None
    assert restaurant.find("josm:multiselect", ns) is None
    assert any(
        "multiCombo field 'diet:' was skipped" in warning for warning in warnings)


def test_single_rapid_preset_discovers_fields_from_checkout_ancestor(tmp_path: Path) -> None:
    preset = tmp_path / "rapid" / "data" / "presets" / "amenity" / "cafe.json"
    fields_dir = tmp_path / "rapid" / "data" / "fields"
    preset.parent.mkdir(parents=True)
    fields_dir.mkdir(parents=True)
    preset.write_text(
        json.dumps({"name": "Cafe", "geometry": ["point"], "tags": {
                   "amenity": "cafe"}, "fields": ["name"]}),
        encoding="utf-8",
    )
    (fields_dir / "name.json").write_text(
        json.dumps({"key": "name", "type": "text", "label": "Name"}),
        encoding="utf-8",
    )

    output = tmp_path / "cafe.xml"
    _, warnings = converter.convert_rapid_to_josm(preset, output)
    root = ET.parse(output).getroot()
    ns = {"josm": "http://josm.openstreetmap.de/tagging-preset-1.0"}
    cafe = root.find("josm:item", ns)

    assert cafe is not None
    assert cafe.find("josm:text[@key='name']", ns) is not None
    assert not any(
        "unresolved field reference 'name'" in warning for warning in warnings)


def test_unresolved_fields_warn_and_skip_without_losing_preset(tmp_path: Path) -> None:
    output = tmp_path / "missing.xml"
    _, warnings = converter.convert_rapid_to_josm(RAPID_FIXTURE, output)
    root = ET.parse(output).getroot()
    ns = {"josm": "http://josm.openstreetmap.de/tagging-preset-1.0"}

    preset = next(item for item in root.findall("josm:item", ns)
                  if item.get("name") == "Preset with missing field")
    assert preset.find("josm:key", ns) is not None
    assert preset.find("josm:text", ns) is None
    assert any("unresolved field reference" in warning for warning in warnings)


def test_josm_combo_preserves_semicolon_delimiter_and_escaped_values(tmp_path: Path) -> None:
    source = tmp_path / "escaped.xml"
    source.write_text(
        '<presets><item name="Escaped"><key key="shop" value="bookshop" />'
        '<combo key="cuisine" text="Cuisine" delimiter=";" '
        'values="coffee\\;tea;herbal\\\\mint" '
        'display_values="Coffee\\;tea;Herbal\\\\mint" /></item></presets>',
        encoding="utf-8",
    )
    output = tmp_path / "rapid"
    converter.convert_josm_to_rapid(source, output)
    field = json.loads(
        (output / "data/fields/cuisine.json").read_text(encoding="utf-8"))

    assert field["options"] == ["coffee;tea", "herbal\\mint"]
    assert field["strings"]["options"] == {
        "coffee;tea": "Coffee;tea",
        "herbal\\mint": "Herbal\\mint",
    }


def test_josm_multiselect_converts_to_semi_combo(tmp_path: Path) -> None:
    output = tmp_path / "rapid"
    converter.convert_josm_to_rapid(JOSM_FIXTURE, output)

    preset = json.loads(
        (output / "data/presets/josm_presets/cafe.json").read_text(encoding="utf-8")
    )
    assert "diet" in preset["fields"]
    diet = json.loads(
        (output / "data/fields/diet.json").read_text(encoding="utf-8"))
    assert diet["type"] == "semiCombo"
    assert diet["key"] == "diet"
    assert diet["options"] == ["vegetarian", "vegan"]


def test_round_trip_preserves_fixed_tags_and_supported_fields(tmp_path: Path) -> None:
    rapid_output = tmp_path / "rapid"
    josm_output = tmp_path / "roundtrip.xml"
    converter.convert_josm_to_rapid(JOSM_FIXTURE, rapid_output)
    converter.convert_rapid_to_josm(rapid_output, josm_output)
    converted_root = ET.parse(josm_output).getroot()
    original_root = ET.parse(JOSM_FIXTURE).getroot()
    ns = {"josm": "http://josm.openstreetmap.de/tagging-preset-1.0"}
    original_item = original_root.find(".//josm:item", ns)
    assert original_item is not None
    converted_item = next(
        item for item in converted_root.findall("josm:item", ns) if item.get("name") == "Cafe"
    )

    original_tags = {(element.get("key"), element.get("value"))
                     for element in original_item.findall("josm:key", ns)}
    converted_tags = {(element.get("key"), element.get("value"))
                      for element in converted_item.findall("josm:key", ns)}
    assert converted_tags == original_tags
    assert {field.get("key") for field in converted_item.findall(
        ".//josm:text", ns)} >= {"name", "phone"}
    assert converted_item.find("josm:combo", ns) is not None
    multiselect = converted_item.find("josm:multiselect", ns)
    assert multiselect is not None
    assert multiselect.get("key") == "diet"


def test_overwrite_refusal_does_not_partially_write_files(tmp_path: Path) -> None:
    output = tmp_path / "rapid"
    existing = output / "data/presets/josm_presets/cafe.json"
    existing.parent.mkdir(parents=True)
    existing.write_text("do not replace", encoding="utf-8")

    with pytest.raises(converter.ConversionError, match="use --overwrite"):
        converter.convert_josm_to_rapid(JOSM_FIXTURE, output)

    assert existing.read_text(encoding="utf-8") == "do not replace"
    assert not (output / "data/fields/name.json").exists()


def test_explicit_overwrite_replaces_all_output_files(tmp_path: Path) -> None:
    output = tmp_path / "rapid"
    existing = output / "data/presets/josm_presets/cafe.json"
    existing.parent.mkdir(parents=True)
    existing.write_text("{}", encoding="utf-8")

    converter.convert_josm_to_rapid(JOSM_FIXTURE, output, overwrite=True)

    assert json.loads(existing.read_text(encoding="utf-8"))["name"] == "Cafe"
    assert (output / "data/fields/name.json").is_file()


def test_malformed_input_and_non_preset_json_are_rejected(tmp_path: Path) -> None:
    malformed_xml = tmp_path / "broken.xml"
    malformed_xml.write_text("<presets>", encoding="utf-8")
    with pytest.raises(converter.ConversionError, match="cannot read JOSM XML"):
        converter.convert_josm_to_rapid(malformed_xml, tmp_path / "rapid")

    non_object = tmp_path / "not-preset.json"
    non_object.write_text("[]", encoding="utf-8")
    with pytest.raises(converter.ConversionError, match="must be an object"):
        converter.convert_rapid_to_josm(non_object, tmp_path / "josm.xml")


def test_preset_ids_cannot_escape_output_directory(tmp_path: Path) -> None:
    with pytest.raises(converter.ConversionError, match="unsafe preset identifier"):
        converter.convert_josm_to_rapid(
            JOSM_FIXTURE, tmp_path / "rapid", preset_id="../outside")


def test_field_id_collision_updates_preset_reference(tmp_path: Path) -> None:
    source = tmp_path / "collisions.xml"
    source.write_text(
        '<presets><item name="First"><key key="shop" value="a" />'
        '<text key="name" text="Name" id="shared.v2" /></item>'
        '<item name="Second"><key key="amenity" value="b" />'
        '<text key="name" text="Display name" id="shared.v2" /></item></presets>',
        encoding="utf-8",
    )
    output = tmp_path / "rapid"
    _, warnings = converter.convert_josm_to_rapid(source, output)

    first = json.loads(
        (output / "data/presets/collisions/first.json").read_text(encoding="utf-8")
    )
    second = json.loads(
        (output / "data/presets/collisions/second.json").read_text(encoding="utf-8")
    )
    assert first["fields"] == ["shared.v2"]
    assert second["fields"] == ["shared.v2_name"]
    assert (output / "data/fields/shared.v2.json").is_file()
    assert (output / "data/fields/shared.v2_name.json").is_file()
    assert any("field ID collision" in warning for warning in warnings)


def test_equal_field_definitions_are_shared_across_presets(tmp_path: Path) -> None:
    source = tmp_path / "shared-fields.xml"
    source.write_text(
        '<presets><item name="First"><key key="shop" value="books" />'
        '<text key="name" text="Name" /></item>'
        '<item name="Second"><key key="shop" value="stationery" />'
        '<text key="name" text="Name" /></item></presets>',
        encoding="utf-8",
    )
    output = tmp_path / "rapid"
    converter.convert_josm_to_rapid(source, output)

    first = json.loads(
        (output / "data/presets/shared_fields/first.json").read_text(encoding="utf-8"))
    second = json.loads(
        (output / "data/presets/shared_fields/second.json").read_text(encoding="utf-8"))
    assert first["fields"] == ["name"]
    assert second["fields"] == ["name"]
    assert len(list((output / "data/fields").rglob("*.json"))) == 1


def test_josm_geometry_distinguishes_point_and_vertex() -> None:
    assert converter.JOSM_GEOMETRIES["point"] == ("node",)
    assert converter.RAPID_GEOMETRIES["node"] == ("point", "vertex")


def test_cli_reports_invalid_source(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    status = converter.main(
        ["josm-to-rapid", str(tmp_path / "missing.xml"), str(tmp_path / "rapid")])

    assert status == 2
    assert "cannot read JOSM XML" in capsys.readouterr().err


def test_josm_combo_preserves_list_entry_display_values(tmp_path: Path) -> None:
    source = tmp_path / "list-entries.xml"
    source.write_text(
        '<presets><item name="Cafe" type="node"><key key="amenity" value="cafe" />'
        '<combo key="cuisine" text="Cuisine" values="italian,tea">'
        '<list_entry value="italian" display_value="Italian" />'
        '<list_entry value="tea" display_value="Tea" /></combo></item></presets>',
        encoding="utf-8",
    )
    output = tmp_path / "rapid"
    converter.convert_josm_to_rapid(source, output)

    field = json.loads(
        (output / "data/fields/cuisine.json").read_text(encoding="utf-8"))
    assert field["options"] == ["italian", "tea"]
    assert field["strings"]["options"] == {"italian": "Italian", "tea": "Tea"}


def test_josm_to_rapid_skips_only_unsupported_geometry(tmp_path: Path) -> None:
    source = tmp_path / "geometry.xml"
    source.write_text(
        '<presets><item name="Unsupported" type="future">'
        '<key key="amenity" value="cafe" /></item>'
        '<item name="Supported" type="node">'
        '<key key="shop" value="books" /></item></presets>',
        encoding="utf-8",
    )
    output = tmp_path / "rapid"
    paths, warnings = converter.convert_josm_to_rapid(source, output)

    assert len(paths) == 1
    preset = json.loads(paths[0].read_text(encoding="utf-8"))
    assert preset["name"] == "Supported"
    assert preset["geometry"] == ["point", "vertex"]
    assert not (output / "data/presets/geometry/unsupported.json").exists()
    assert any("no supported geometry; skipped" in warning for warning in warnings)


def test_josm_to_rapid_rejects_only_unsupported_geometries(tmp_path: Path) -> None:
    source = tmp_path / "unsupported.xml"
    source.write_text(
        '<presets><item name="Unsupported" type="future">'
        '<key key="amenity" value="cafe" /></item></presets>',
        encoding="utf-8",
    )

    with pytest.raises(converter.ConversionError, match="no convertible JOSM presets"):
        converter.convert_josm_to_rapid(source, tmp_path / "rapid")


def test_rapid_to_josm_rejects_only_unsupported_geometries(tmp_path: Path) -> None:
    source = tmp_path / "unsupported.json"
    source.write_text(
        json.dumps({
            "name": "Unsupported",
            "geometry": ["future"],
            "tags": {"amenity": "cafe"},
        }),
        encoding="utf-8",
    )

    with pytest.raises(converter.ConversionError, match="no convertible Rapid presets"):
        converter.convert_rapid_to_josm(source, tmp_path / "unsupported.xml")


def test_duplicate_preset_id_suffix_collision_does_not_overwrite(
    tmp_path: Path,
) -> None:
    source = tmp_path / "collisions.xml"
    source.write_text(
        '<presets><item name="alpha_2_3_4"><key key="test" value="first" /></item>'
        '<item name="alpha_2_3"><key key="test" value="second" /></item>'
        '<item name="other"><key key="test" value="third" /></item>'
        '<item name="alpha_2_3"><key key="test" value="fourth" /></item></presets>',
        encoding="utf-8",
    )
    output = tmp_path / "rapid"
    paths, warnings = converter.convert_josm_to_rapid(source, output)

    preset_files = list((output / "data/presets/collisions").glob("*.json"))
    values = {
        json.loads(path.read_text(encoding="utf-8"))["tags"]["test"]
        for path in preset_files
    }
    assert len(paths) == 4
    assert len(preset_files) == 4
    assert values == {"first", "second", "third", "fourth"}
    assert any("preset ID collision" in warning for warning in warnings)


def test_rapid_data_directory_discovers_only_presets(tmp_path: Path) -> None:
    output = tmp_path / "converted.xml"
    _, warnings = converter.convert_rapid_to_josm(
        RAPID_FIXTURE / "data", output)

    root = ET.parse(output).getroot()
    assert len(root) == 2
    assert not any("without a tags object" in warning for warning in warnings)


def test_field_only_josm_preset_is_preserved_without_skip_warning(
    tmp_path: Path,
) -> None:
    source = tmp_path / "field-only.xml"
    source.write_text(
        '<presets><item name="Roadway" type="way">'
        '<text key="highway" text="Highway" /></item></presets>',
        encoding="utf-8",
    )
    output = tmp_path / "rapid"
    paths, warnings = converter.convert_josm_to_rapid(source, output)

    preset = json.loads(
        (output / "data/presets/field_only/roadway.json").read_text(
            encoding="utf-8"))
    assert preset["tags"] == {}
    assert preset["fields"] == ["highway"]
    assert len(paths) == 2
    assert not any("no fixed tags" in warning for warning in warnings)
