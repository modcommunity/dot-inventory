@tool
class_name DotInvQuery
extends RefCounted

## Sorting and filtering, applied locally and never by a server.
##
## [b]dot-browser's rule, and it is the same rule for the same reason.[/b] A filter is a
## question about what one person wants to look at; sending it to a server makes the
## server responsible for a preference, costs a round trip per keystroke, and gives a
## player a list that lags behind their own typing. The server owns what is in the
## inventory; the client owns how it is shown.
##
## [codeblock]
## var q := DotInvQuery.new()
## q.text = "rifle"
## q.tags = [&"weapon"]
## q.sort_by = DotInvQuery.Sort.WEIGHT
## for hit in q.run(manager.doc, catalogue):
##     ...
## [/codeblock]

enum Sort {
	## The order they are in. What a player arranged by hand.
	NONE,
	NAME,
	WEIGHT,
	COUNT,
	KIND,
}

## Free text, matched against the id and the name key, case-insensitively.
var text: String = ""

## Every one of these must be present.
var tags: Array[StringName] = []

## Any of these kinds. Empty accepts all.
var kinds: Array[int] = []

## Only these containers. Empty searches all of them.
var containers: Array[StringName] = []

var sort_by: Sort = Sort.NONE
var descending: bool = false


## Returns [code]{container, uid, item, entry}[/code] for everything that matches.
func run(doc: DotInvDoc, catalogue: DotInvCatalogue) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var needle := text.to_lower()

	for container_id in doc.ordered_ids():
		if not containers.is_empty() and not containers.has(container_id):
			continue
		var c: DotInvContainer = doc.get_container(container_id)
		for uid in c.entries.keys():
			var entry: Dictionary = c.entries[uid]
			var item := catalogue.find(StringName(str(entry.get("item", ""))))
			if item == null:
				continue
			if not kinds.is_empty() and not kinds.has(int(item.kind)):
				continue
			if needle != "":
				var hay := (String(item.id) + " " + String(item.name_key)).to_lower()
				if not hay.contains(needle):
					continue
			var missing := false
			for t in tags:
				if not item.has_tag(t):
					missing = true
					break
			if missing:
				continue
			out.append({
				"container": container_id, "uid": uid, "item": item, "entry": entry
			})

	if sort_by != Sort.NONE:
		out.sort_custom(_comparator)
		if descending:
			out.reverse()
	return out


func _comparator(a: Dictionary, b: Dictionary) -> bool:
	var ia: DotInvItem = a["item"]
	var ib: DotInvItem = b["item"]
	match sort_by:
		Sort.WEIGHT:
			var wa := ia.weight * float((a["entry"] as Dictionary).get("count", 1))
			var wb := ib.weight * float((b["entry"] as Dictionary).get("count", 1))
			# A tie-break on the id, always. sort_custom is not stable in Godot, so two
			# items of equal weight come out in an order that depends on where they
			# happened to be -- and a sorted list that reshuffles its ties every time it
			# is redrawn looks like a bug in the inventory.
			return wa < wb if not is_equal_approx(wa, wb) else String(ia.id) < String(ib.id)
		Sort.COUNT:
			var ca := int((a["entry"] as Dictionary).get("count", 1))
			var cb := int((b["entry"] as Dictionary).get("count", 1))
			return ca < cb if ca != cb else String(ia.id) < String(ib.id)
		Sort.KIND:
			return int(ia.kind) < int(ib.kind) if ia.kind != ib.kind else String(ia.id) < String(ib.id)
		_:
			# By id rather than by name_key: a name key is a translation key, so sorting
			# by it sorts by whatever the keys happen to be called rather than by what a
			# player reads. Sorting by the displayed name is the game's job, because only
			# the game has the translation.
			return String(ia.id) < String(ib.id)
