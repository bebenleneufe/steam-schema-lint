@tool
extends RefCounted
## Export VDF pour Steamworks.
##
## Structure relevée sur un export réel (`tests/fixtures/gambit_loop_raw.txt`,
## app 4531320), pas reconstituée : racine = appid, `stats` → une stat par
## **groupe** d'achievements, chacune avec son bloc `bits` puis `"type"
## "ACHIEVEMENTS"`, et enfin `version` et `gamename` au niveau de l'app.
##
## Les icônes sont référencées par le nom de fichier que Steam attribue à
## l'upload (un hash). Ce n'est pas un chemin qu'on peut inventer : quand on
## connaît le hash — après un import — on le réémet tel quel. Sinon on écrit le
## nom du fichier généré localement et un avertissement explicite dit qu'il faut
## uploader les icônes dans Steamworks puis réimporter pour capturer les hashs.
##
## Les stats ordinaires (INT / FLOAT / AVGRATE) sont écrites dans la forme
## relevée sur le même export : `type`, `name`, `display.name`, puis les options
## `maxchange`, `incrementonly`, `min`, `max`, `default`, `windowsize` et
## `permission`, chacune n'apparaissant que si elle est définie — comme Steam le
## fait lui-même. L'identifiant numérique d'une stat vient de Steam et est
## réutilisé tel quel, jamais réinventé.

const TAB := "\t"


## VDF complet, déterministe : deux exports du même schéma donnent des octets
## identiques (groupes triés, achievements triés par bit, langues dans l'ordre
## déclaré).
static func achievements_vdf(model) -> String:
	var lines: Array = []
	lines.append(_q(str(model.appid)))
	lines.append("{")
	lines.append(TAB + _q("stats"))
	lines.append(TAB + "{")

	var group_ids := ordered_group_ids(model)
	for group_id in group_ids:
		lines.append(TAB.repeat(2) + _q(str(group_id)))
		lines.append(TAB.repeat(2) + "{")
		lines.append(TAB.repeat(3) + _q("bits"))
		lines.append(TAB.repeat(3) + "{")

		for ach in _achievements_in_group(model, str(group_id)):
			lines.append(TAB.repeat(4) + _q(str(int(ach.get("bit", 0)))))
			lines.append(TAB.repeat(4) + "{")
			lines.append(TAB.repeat(5) + _q("name") + TAB + _q(str(ach.get("api_name", ""))))
			lines.append(TAB.repeat(5) + _q("display"))
			lines.append(TAB.repeat(5) + "{")

			var display: Dictionary = ach.get("display", {})
			lines.append(TAB.repeat(6) + _q("name"))
			lines.append(TAB.repeat(6) + "{")
			for lang in _language_order(model, display):
				var entry: Dictionary = display.get(lang, {})
				lines.append(TAB.repeat(7) + _q(lang) + TAB + _q(str(entry.get("name", ""))))
			lines.append(TAB.repeat(6) + "}")

			lines.append(TAB.repeat(6) + _q("desc"))
			lines.append(TAB.repeat(6) + "{")
			for lang in _language_order(model, display):
				var entry: Dictionary = display.get(lang, {})
				lines.append(TAB.repeat(7) + _q(lang) + TAB + _q(str(entry.get("desc", ""))))
			lines.append(TAB.repeat(6) + "}")

			lines.append(TAB.repeat(6) + _q("hidden") + TAB + _q("1" if bool(ach.get("hidden", false)) else "0"))
			var api_name := str(ach.get("api_name", ""))
			lines.append(TAB.repeat(6) + _q("icon") + TAB + TAB + _q(icon_reference(ach)))
			var gray_ref := str(ach.get("remote_icon_gray", ""))
			if gray_ref.is_empty():
				gray_ref = "%s_gray.jpg" % api_name.to_lower()
			lines.append(TAB.repeat(6) + _q("icon_gray") + TAB + _q(gray_ref))
			lines.append(TAB.repeat(5) + "}")
			lines.append(TAB.repeat(4) + "}")

		lines.append(TAB.repeat(3) + "}")
		lines.append(TAB.repeat(3) + _q("type") + TAB + _q(model.group_type(str(group_id))))
		lines.append(TAB.repeat(2) + "}")

	var stat_ids := assign_stat_ids(model)
	for i in model.stats.size():
		_write_stat(lines, model.stats[i], stat_ids[i])

	lines.append(TAB + "}")
	if not str(model.vdf_version).is_empty():
		lines.append(TAB + _q("version") + TAB + _q(str(model.vdf_version)))
	if not str(model.gamename).is_empty():
		lines.append(TAB + _q("gamename") + TAB + _q(str(model.gamename)))
	lines.append("}")
	return "\n".join(lines) + "\n"


## Référence d'icône : le hash fourni par Steam s'il est connu, sinon le nom du
## fichier généré localement (à uploader avant import du VDF).
static func icon_reference(ach: Dictionary) -> String:
	var remote := str(ach.get("remote_icon", ""))
	if not remote.is_empty():
		return remote
	return "%s.jpg" % str(ach.get("api_name", "")).to_lower()


## Export complet : valide, refuse si erreur, écrit le fichier.
## Retourne { ok, path, errors: Array[String], warnings: Array[String] }.
static func export_file(model, out_path: String, validator_script: GDScript) -> Dictionary:
	var result := {"ok": false, "path": out_path, "errors": [], "warnings": []}

	var issues: Array = validator_script.validate(model)
	for issue in issues:
		if issue["severity"] == "error":
			result["errors"].append("%s: %s" % [issue["code"], issue["message"]])
		else:
			result["warnings"].append("%s: %s" % [issue["code"], issue["message"]])

	var missing_hashes := 0
	for ach in model.achievements:
		if str(ach.get("remote_icon", "")).is_empty():
			missing_hashes += 1
	if missing_hashes > 0:
		result["warnings"].append("ICON_HASH_MISSING: %d achievement(s) have no icon hash from Steam. The VDF points at the locally generated file names; upload those images in the Steamworks UI, then re-import the raw settings to capture their hashes." % missing_hashes)

	if not result["errors"].is_empty():
		return result

	# Projet neuf : res://steam/ n'existe pas encore.
	var dir := out_path.get_base_dir()
	if not dir.is_empty() and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		result["errors"].append("WRITE_FAILED: cannot open %s (error %d)" % [out_path, FileAccess.get_open_error()])
		return result
	f.store_string(achievements_vdf(model))
	f.close()
	result["ok"] = true
	return result


# --- Stats --------------------------------------------------------------------

## Écrit une stat ordinaire. Ordre et clés relevés sur un export réel : type,
## name, display.name, puis maxchange / incrementonly / min / max / default /
## windowsize / permission — chaque option n'apparaissant que si elle est
## définie, exactement comme Steamworks l'écrit.
static func _write_stat(lines: Array, st: Dictionary, stat_id: String) -> void:
	var type := str(st.get("type", "INT"))
	lines.append(TAB.repeat(2) + _q(stat_id))
	lines.append(TAB.repeat(2) + "{")
	lines.append(TAB.repeat(3) + _q("type") + TAB + _q(type))
	lines.append(TAB.repeat(3) + _q("name") + TAB + _q(str(st.get("api_name", ""))))
	lines.append(TAB.repeat(3) + _q("display"))
	lines.append(TAB.repeat(3) + "{")
	lines.append(TAB.repeat(4) + _q("name") + TAB + _q(str(st.get("display_name", ""))))
	lines.append(TAB.repeat(3) + "}")
	if int(st.get("max_change", 0)) != 0:
		lines.append(TAB.repeat(3) + _q("maxchange") + TAB + _q(_plain_number(st.get("max_change", 0))))
	if bool(st.get("increment_only", false)):
		lines.append(TAB.repeat(3) + _q("incrementonly") + TAB + _q("1"))
	lines.append(TAB.repeat(3) + _q("min") + TAB + TAB + _q(_plain_number(st.get("min", 0))))
	lines.append(TAB.repeat(3) + _q("max") + TAB + TAB + _q(_plain_number(st.get("max", 0))))
	lines.append(TAB.repeat(3) + _q("default") + TAB + _q(_plain_number(st.get("default", 0))))
	if type == "AVGRATE":
		lines.append(TAB.repeat(3) + _q("windowsize") + TAB + _q("%.1f" % float(st.get("window_size", 0.0))))
	var permission := str(st.get("permission", ""))
	if not permission.is_empty():
		lines.append(TAB.repeat(3) + _q("permission") + TAB + _q(permission))
	lines.append(TAB.repeat(2) + "}")


## Un entier s'écrit « 2000 », un flottant « 12.5 ». Steamworks ne met pas de
## « .0 » sur les valeurs rondes (sauf windowsize, qui en a toujours un).
static func _plain_number(value: Variant) -> String:
	var f := float(value)
	if is_equal_approx(f, round(f)):
		return "%d" % int(round(f))
	return str(f)


## L'identifiant numérique d'une stat vient de Steam : on le réutilise tel quel
## quand on le connaît, sinon on prend le premier numéro libre.
## Identifiant VDF de chaque stat, dans l'ordre de `model.stats`. Un identifiant
## attribué est aussitôt marqué pris : avant, deux stats neuves sans ID
## recevaient le même, et Steam n'en gardait qu'une.
static func assign_stat_ids(model) -> Array:
	var taken := {}
	for st in model.stats:
		var sid := str(st.get("stat_id", ""))
		if not sid.is_empty():
			taken[sid] = true
	for gid in ordered_group_ids(model):
		taken[str(gid)] = true
	var out: Array = []
	var candidate := 1
	for st in model.stats:
		var explicit := str(st.get("stat_id", ""))
		if not explicit.is_empty():
			out.append(explicit)
			continue
		while taken.has(str(candidate)):
			candidate += 1
		taken[str(candidate)] = true
		out.append(str(candidate))
	return out


# --- Utilitaires --------------------------------------------------------------

## Identifiants de groupe, triés numériquement quand ils le sont.
static func ordered_group_ids(model) -> Array:
	var ids: Array = []
	for g in model.groups:
		ids.append(str(g["stat_id"]))
	for ach in model.achievements:
		var gid := str(ach.get("group", model.default_group()))
		if not ids.has(gid):
			ids.append(gid)
	ids.sort_custom(func(a, b):
		if str(a).is_valid_int() and str(b).is_valid_int():
			return str(a).to_int() < str(b).to_int()
		return str(a) < str(b))
	return ids


static func _achievements_in_group(model, group_id: String) -> Array:
	var out: Array = []
	for ach in model.achievements:
		if str(ach.get("group", model.default_group())) == group_id:
			out.append(ach)
	out.sort_custom(func(a, b): return int(a.get("bit", 0)) < int(b.get("bit", 0)))
	return out


## Langues déclarées dans l'ordre du schéma, puis les autres (triées) : rien
## n'est perdu, y compris la pseudo-langue « token » que Steam place dans chaque
## bloc une fois le jeu localisé. Les entrées vides sont écartées.
static func _language_order(model, display: Dictionary) -> Array:
	var order: Array = []
	for lang in model.languages:
		if _has_text(display, str(lang)) and not order.has(str(lang)):
			order.append(str(lang))
	var extras: Array = []
	for lang in display.keys():
		if _has_text(display, str(lang)) and not order.has(str(lang)):
			extras.append(str(lang))
	extras.sort()
	return order + extras


static func _has_text(display: Dictionary, lang: String) -> bool:
	if not display.has(lang):
		return false
	var entry: Dictionary = display.get(lang, {})
	var name := str(entry.get("name", "")).strip_edges()
	var desc := str(entry.get("desc", "")).strip_edges()
	return not name.is_empty() or not desc.is_empty()


static func _q(value: String) -> String:
	return "\"%s\"" % value.replace("\\", "\\\\").replace("\"", "\\\"")
