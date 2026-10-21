@tool
extends EditorPlugin
## Cette extension n'ajoute aucun élément d'interface : c'est une bibliothèque
## (validateur, lecteur/écrivain VDF, scanner) pilotée en ligne de commande.
## L'entrée existe parce que le Godot Asset Store référence les extensions par
## leur plugin.cfg ; l'activer ne change donc rien dans l'éditeur.


func _get_plugin_name() -> String:
	return "Steam Schema Lint"
