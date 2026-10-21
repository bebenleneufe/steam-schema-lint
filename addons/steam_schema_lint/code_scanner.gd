@tool
extends RefCounted
## Scan du code (M7) — la raison d'être du produit.
##
## L'éditeur d'achievements de Valve sait ce qu'il y a dans le back-end. Il ne
## sait pas ce que le jeu appelle. Un `Steam.setAchievement("ACH_BOSS_DEFEAT")`
## mal orthographié renvoie `false` en silence : aucune erreur, aucun log, aucun
## succès débloqué. C'est le seul angle que Valve ne peut pas couvrir, parce
## qu'il ne lit pas le code du jeu.
##
## Limite assumée : le scan est ligne par ligne. Un appel dont l'argument est sur
## la ligne suivante n'est pas détecté. Les commentaires `#` sont ignorés.

const ACHIEVEMENT_FUNCS := [
	"setAchievement", "getAchievement", "indicateAchievementProgress",
	"getAchievementDisplayAttribute", "clearAchievement",
]
const STAT_FUNCS := [
	"setStatInt", "setStatFloat", "getStatInt", "getStatFloat",
]
# storeStats() ne prend aucun nom : le scanner le prenait pour un appel avec un
# nom calculé et levait un UNRESOLVED_NAME à chaque sauvegarde des stats.
const SKIP_DIRS := ["addons", ".godot", ".git", ".import", ".godot-cache"]


## Scanne un projet entier.
## Retourne { ok, files_scanned, calls, findings: Array[Dictionary], errors: Array[String] }
## Un finding : { severity, code, file, line, api_name, message }
static func scan_project(model, root := "res://", skip_dirs: Array = []) -> Dictionary:
	var result := {"ok": true, "files_scanned": 0, "calls": 0, "findings": [], "errors": []}
	var skipped := SKIP_DIRS.duplicate()
	skipped.append_array(skip_dirs)
	var files := _list_scripts(root, skipped)
	if files.is_empty():
		result["ok"] = false
		result["errors"].append("NO_SCRIPTS: no .gd file found under %s." % root)
		return result

	var referenced_achievements := {}
	var referenced_stats := {}
	for path in files:
		var text := FileAccess.get_file_as_string(path)
		if text.is_empty():
			result["errors"].append("UNREADABLE: %s" % path)
			continue
		result["files_scanned"] += 1
		var found := scan_script(path, text, model)
		result["calls"] += int(found["calls"])
		result["findings"].append_array(found["findings"])
		for name in found["achievements"]:
			referenced_achievements[name] = true
		for name in found["stats"]:
			referenced_stats[name] = true

	# Ce qui est déclaré mais jamais débloqué : souvent un achievement oublié, à
	# défaut d'être branché depuis des données ou du code natif. Avertissement,
	# pas erreur — le schéma peut être en avance sur le code.
	for ach in model.achievements:
		var api_name := str(ach.get("api_name", ""))
		if api_name.is_empty() or referenced_achievements.has(api_name):
			continue
		result["findings"].append(_finding("warning", "ACH_UNUSED", "", 0, api_name,
			"Declared but never unlocked anywhere in the scanned code."))
	for st in model.stats:
		var api_name := str(st.get("api_name", ""))
		if api_name.is_empty() or referenced_stats.has(api_name):
			continue
		result["findings"].append(_finding("warning", "STAT_UNUSED", "", 0, api_name,
			"Declared but never read or written in the scanned code."))

	return result


## Constantes de chaîne du fichier, pour résoudre `setAchievement(ACH_NAME)`.
static func _string_constants(text: String) -> Dictionary:
	var out := {}
	# `:=`, `: String =` et `=` : les trois formes d'un const typé ou non.
	var re := RegEx.create_from_string("const\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*(?::\\s*[A-Za-z_][A-Za-z0-9_]*)?\\s*:?=\\s*\"([^\"]*)\"")
	for m in re.search_all(text):
		out[m.get_string(1)] = m.get_string(2)
	return out


## Scanne un seul script.
## Retourne { calls: int, findings: Array, achievements: Array, stats: Array }
static func scan_script(path: String, text: String, model) -> Dictionary:
	var out := {"calls": 0, "findings": [], "achievements": [], "stats": []}
	var consts := _string_constants(text)
	var lines := text.split("\n")
	for index in lines.size():
		var line := _strip_comment(lines[index])
		if line.find("Steam") == -1:
			continue
		var line_no := index + 1

		for call in _calls_on_line(line):
			out["calls"] += 1
			var func_name: String = call["func"]
			var is_achievement := ACHIEVEMENT_FUNCS.has(func_name)
			var is_stat := STAT_FUNCS.has(func_name)
			if not is_achievement and not is_stat:
				continue

			var arg: String = call["arg"]
			var is_literal: bool = call["literal"]

			if not is_literal and consts.has(arg):
				# `const ACH_X := "ACH_X"` puis setAchievement(ACH_X) : le nom est
				# écrit noir sur blanc dans le fichier. Sans cette résolution, le
				# succès passait pour incalculable ET pour jamais débloqué.
				arg = str(consts[arg])
				is_literal = true

			if not is_literal:
				# Nom calculé (variable, concaténation) : on ne peut pas le
				# résoudre, mais on le signale — c'est là que se cachent les
				# fautes de frappe invisibles.
				out["findings"].append(_finding("warning", "UNRESOLVED_NAME", path, line_no, arg,
					"%s() is called with a computed value (%s) — the name cannot be checked." % [func_name, arg]))
				continue

			if is_achievement:
				out["achievements"].append(arg)
				if model.find_achievement(arg).is_empty():
					out["findings"].append(_finding("error", "UNKNOWN_ACHIEVEMENT", path, line_no, arg,
						"%s(\"%s\") — no such achievement in the schema.%s" % [func_name, arg, _suggestion(model, arg)]))
			elif is_stat:
				out["stats"].append(arg)
				var stat: Dictionary = model.find_stat(arg)
				if stat.is_empty():
					out["findings"].append(_finding("error", "UNKNOWN_STAT", path, line_no, arg,
						"%s(\"%s\") — no such stat in the schema.%s" % [func_name, arg, _suggestion(model, arg)]))
				else:
					var stat_type := str(stat.get("type", ""))
					if func_name == "setStatInt" and stat_type != "INT":
						out["findings"].append(_finding("error", "STAT_TYPE_MISMATCH", path, line_no, arg,
							"setStatInt(\"%s\") but the stat is declared %s — the value will be silently wrong." % [arg, stat_type]))
					elif func_name == "setStatFloat" and stat_type == "INT":
						out["findings"].append(_finding("error", "STAT_TYPE_MISMATCH", path, line_no, arg,
							"setStatFloat(\"%s\") but the stat is declared INT — the value will be silently wrong." % [arg]))
	return out


# --- Analyse d'une ligne ------------------------------------------------------

## Repère les appels `Steam.xxx(...)` et dit si le premier argument est un
## littéral de chaîne.
static func _calls_on_line(line: String) -> Array:
	var calls: Array = []
	var re := RegEx.create_from_string("Steam\\s*\\.\\s*([A-Za-z_][A-Za-z0-9_]*)\\s*\\(")
	for m in re.search_all(line):
		var func_name := m.get_string(1)
		var rest := line.substr(m.get_end())
		var arg := ""
		var literal := false
		var stripped := rest.strip_edges(true, false)
		# Un appel écrit à l'intérieur d'une chaîne GDScript arrive ici avec des
		# guillemets échappés : `Steam.setAchievement(\"ACH_X\")`. Sans ce
		# décalage, le scanner prendrait un littéral pour une valeur calculée.
		var offset := 0
		if stripped.length() > 1 and stripped[0] == "\\" and (stripped[1] == "\"" or stripped[1] == "'"):
			offset = 1
		if stripped.length() > offset and (stripped[offset] == "\"" or stripped[offset] == "'"):
			var quote := stripped[offset]
			var close := stripped.find(quote, offset + 1)
			if close != -1:
				arg = stripped.substr(offset + 1, close - offset - 1)
				# Guillemets échappés : la barre oblique inverse qui précède la
				# fermeture fait partie du texte brut, pas du nom.
				if arg.ends_with("\\"):
					arg = arg.substr(0, arg.length() - 1)
				# « ach_chain_%d » n'est pas un nom vérifiable : c'est une chaîne
				# formatée, donc une valeur calculée qu'on signale sans deviner.
				var format_re := RegEx.create_from_string("%[sdfxXv]")
				literal = format_re.search(arg) == null
		if not literal:
			# Nom calculé : on garde l'expression jusqu'à la virgule ou la parenthèse.
			var stop := rest.find(",")
			var paren := rest.find(")")
			if stop == -1 or (paren != -1 and paren < stop):
				stop = paren
			if stop == -1:
				stop = rest.length()
			arg = rest.substr(0, stop).strip_edges()
		calls.append({"func": func_name, "arg": arg, "literal": literal})
	return calls


## Retire un commentaire `#` de fin de ligne, sans toucher aux `#` dans les
## chaînes : sinon un `"#hashtag"` tronquerait la ligne.
static func _strip_comment(line: String) -> String:
	var in_string := false
	var quote := ""
	var i := 0
	while i < line.length():
		var c := line[i]
		if in_string:
			if c == "\\":
				i += 2
				continue
			if c == quote:
				in_string = false
		elif c == "\"" or c == "'":
			in_string = true
			quote = c
		elif c == "#":
			return line.substr(0, i)
		i += 1
	return line


static func _suggestion(model, name: String) -> String:
	var lowered := name.to_lower()
	for ach in model.achievements:
		if str(ach.get("api_name", "")).to_lower() == lowered:
			return " Did you mean \"%s\"? API names are case-sensitive." % str(ach["api_name"])
	for st in model.stats:
		if str(st.get("api_name", "")).to_lower() == lowered:
			return " Did you mean \"%s\"? API names are case-sensitive." % str(st["api_name"])
	return ""


# --- Parcours des fichiers ----------------------------------------------------

static func _list_scripts(root: String, skip_dirs: Array) -> Array:
	var files: Array = []
	var dir := DirAccess.open(root)
	if dir == null:
		return files
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry.begins_with("."):
			entry = dir.get_next()
			continue
		var path := root.path_join(entry)
		if dir.current_is_dir():
			if not skip_dirs.has(entry):
				files.append_array(_list_scripts(path, skip_dirs))
		elif entry.ends_with(".gd"):
			files.append(path)
		entry = dir.get_next()
	dir.list_dir_end()
	files.sort()
	return files


static func _finding(severity: String, code: String, file: String, line: int, api_name: String, message: String) -> Dictionary:
	return {
		"severity": severity,
		"code": code,
		"file": file,
		"line": line,
		"api_name": api_name,
		"message": message,
	}
