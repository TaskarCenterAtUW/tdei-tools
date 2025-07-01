# Element Query Documentation

The `quest_query` attribute of a GoInfoGame long form quest definition is constructed in a similar way to an OverPass API query, with some modifications.

Eg. To get all ways, simply enter the query: `ways`

## Cheatsheet for element filter syntax

| Expression                   | [matches] returns `true` if element...                                                                                    |
|:-----------------------------|:--------------------------------------------------------------------------------------------------------------------------|
| `shop`                       | has a tag with key `shop`                                                                                                 |
| `!shop`                      | doesn't have a tag with key `shop`                                                                                        |
| `shop = car`                 | has a tag with key `shop` whose value is `car`                                                                            |
| `shop != car`                | doesn't have a tag with key `shop` whose value is `car`                                                                   |
| `~shop\|craft`               | has a tag whose key matches the regex `shop\|craft`                                                                       |
| `!~shop\|craft`              | doesn't have a tag whose key matches the regex `shop\|craft`                                                              |
| `shop ~ car\|boat`           | has a tag whose key is `shop` and whose value matches the regex `car\|boat`                                               |
| `shop !~ car\|boat`          | doesn't have a tag whose key is `shop` and value matches the regex `car\|boat`                                            |
| `~shop\|craft ~ car\|boat`   | has a tag whose key matches `shop\|craft` and value matches `car\|boat` (both regexes)                                    |
| `~shop\|craft !~ car\|boat`  | doesn't have a tag whose key matches `shop\|craft` and value matches `car\|boat` (both regexes)                           |
| `foo < 3.3`                  | has a tag with key `foo` whose value is smaller than 2.5<br/>`<`,`<=`,`>=`,`>` work likewise                              |
| `foo < 3.3ft`                | same as above but value is smaller than 3.3 feet (~1 meter)<br/>This works for other units as well (mph, st, lbs, yds...) |
| `foo < 3'4"`                 | same as above but value is smaller than 3 feet, 4 inches (~1 meter)                                                       |
| `foo < 2012-10-01`           | same as above but value is a date older than Oct 1st 2012                                                                 |
| `foo < today -1.5 years`     | same as above but value is a date older than 1.5 years<br/>In place of `years`, `months`, `weeks` or `days` also work     |
| `shop newer today -99 days`  | has a tag with key `shop` which has been modified in the last 99 days. Absolute dates work as well.                       |
| `shop older today -1 months` | has a tag with key `shop` which hasn't been changed for more than a month. Absolute dates work as well.                   |
| `shop and name`              | has both a tag with key `shop` and a tag with key `name`                                                                  |
| `shop or craft`              | has either a tag with key `shop` or a tag with key `craft`                                                                |
| `shop and (ref or name)`     | has a tag with key `shop` and either a tag with key `ref` or a tag with key `name`                                        |
| `shop and !(ref or name)`    | has a tag with key `shop` but not either a tag with key `ref` or a tag with key `name`                                    |

Note that regexes have to match the whole string, i.e. `~shop\|craft` does not match `shop_type`.

## Equivalent expressions

| Expression                  | Equivalent Expression                                    |
|:----------------------------|:---------------------------------------------------------|
| `shop and shop = boat`      | `shop = boat`                                            |
| `!shop or shop != boat`     | `shop != boat`                                           |
| `shop = car or shop = boat` | `shop ~ car\|boat`                                       |
| `craft or shop and name`    | `craft or (shop and name)` (`and` has higher precedence) |
| `!(amenity and craft)`      | `!amenity or !craft`                                     |
| `!(amenity or craft)`       | `!amenity and !craft`                                    |

The queries can be combined with parenthesis and can also be used for matching with multiple tag filters.

## Example queries:

- Get all sidewalks: `ways with (footway=sidewalk)`

- Get all sidewalks without a surface tag: `ways with (footway=sidewalk and !surface)`

- Get all kerbs without a tactile_paving tag: `nodes with (barrier=kerb and !tactile_paving)`
