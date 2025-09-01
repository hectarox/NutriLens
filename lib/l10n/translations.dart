part of '../main.dart';

// Minimal localization helper (English/French)
class S {
  final Locale locale;
  S(this.locale);

  static S of(BuildContext context) {
    final loc = appSettings.locale ?? Localizations.maybeLocaleOf(context) ?? const Locale('en');
    return S(loc);
  }

  String get _code => locale.languageCode;

  String get appTitle => _code == 'fr' ? 'Gestionnaire de repas' : 'Meal Manager';
  String get healthConnect => _code == 'fr' ? 'Health Connect' : 'Health Connect';
  String get hcUnknown => _code == 'fr' ? 'Statut inconnu' : 'Status unknown';
  String get hcAuthorized => _code == 'fr' ? 'Autorisé' : 'Authorized';
  String get hcNotAuthorized => _code == 'fr' ? 'Non autorisé' : 'Not authorized';
  String get lastError => _code == 'fr' ? 'Dernière erreur' : 'Last error';
  // Flash popup and error strings
  String get flashTitle => _code == 'fr' ? 'Utiliser le modèle flash ?' : 'Use flash model?';
  String get flashExplain => _code == 'fr'
      ? 'Cela va réessayer une fois avec un modèle plus rapide et moins précis (gemini-2.5-flash).'
      : 'This will retry once with a faster, less precise model (gemini-2.5-flash).';
  String get useFlash => _code == 'fr' ? 'Utiliser flash' : 'Use flash';
  String get aiOverloaded => _code == 'fr' ? 'L’IA est surchargée (503).' : 'AI is overloaded (503).';
  String requestFailedWithCode(int code) => _code == 'fr' ? 'Échec de la requête ($code)' : 'Request failed ($code)';
  String get checkStatus => _code == 'fr' ? 'Vérifier le statut' : 'Check status';
  String get grantPermissions => _code == 'fr' ? 'Autoriser' : 'Grant permissions';
  String get hcGranted => _code == 'fr' ? 'Autorisations accordées' : 'Permissions granted';
  String get hcDenied => _code == 'fr' ? 'Autorisations refusées' : 'Permissions denied';
  String get hcWriteOk => _code == 'fr' ? 'Enregistré dans Health Connect' : 'Saved to Health Connect';
  String get hcWriteFail => _code == 'fr' ? "Échec de l’enregistrement dans Health Connect" : 'Failed to write to Health Connect';
  String get installHc => _code == 'fr' ? 'Installer Health Connect' : 'Install Health Connect';
  String get updateHc => _code == 'fr' ? 'Mettre à jour Health Connect' : 'Update Health Connect';
  String get settings => _code == 'fr' ? 'Paramètres' : 'Settings';
  String get systemLanguage => _code == 'fr' ? 'Langue du système' : 'System language';
  String get theme => _code == 'fr' ? 'Thème' : 'Theme';
  String get systemTheme => _code == 'fr' ? 'Thème du système' : 'System theme';
  String get lightTheme => _code == 'fr' ? 'Thème clair' : 'Light theme';
  String get darkTheme => _code == 'fr' ? 'Thème sombre' : 'Dark theme';
  String get daltonianMode => _code == 'fr' ? 'Mode daltonien' : 'Colorblind-friendly mode';
  String get daltonianModeHint => _code == 'fr' ? 'Améliore les contrastes et couleurs pour les daltoniens' : 'Improves contrasts and colors for color vision deficiencies';
  String get tabHistory => _code == 'fr' ? 'Historique' : 'History';
  String get tabMain => _code == 'fr' ? 'Principal' : 'Main';
  String get tabDaily => _code == 'fr' ? 'Quotidien' : 'Daily';

  String get describeMeal => _code == 'fr' ? 'Indiquez des précisions pour aider l\'IA' : 'Provide details to help the AI';
  String get describeMealHint => _code == 'fr' ? 'ex. poulet, riz, salade…' : 'e.g. chicken, rice, salad…';
  String get takePhoto => _code == 'fr' ? 'Prendre une photo' : 'Take Photo';
  String get pickImage => _code == 'fr' ? 'Choisir une image' : 'Pick Image';
  String get sendToAI => _code == 'fr' ? 'Envoyer à l’IA' : 'Send to AI';
  String get scanBarcode => _code == 'fr' ? 'Scanner code-barres' : 'Scan barcode';
  String get sending => _code == 'fr' ? 'Envoi…' : 'Sending…';
  String get provideMsgOrImage => _code == 'fr' ? 'Veuillez fournir un message ou une image.' : 'Please provide a message or an image.';
  String get cameraNotSupported => _code == 'fr' ? 'La capture photo n’est pas prise en charge sur cette plateforme. Utilisez Choisir une image.' : 'Camera capture not supported on this platform. Use Pick Image instead.';
  String get failedOpenCamera => _code == 'fr' ? 'Impossible d’ouvrir la caméra' : 'Failed to open camera';
  String get requestFailed => _code == 'fr' ? 'Échec de la requête' : 'Request failed';
  String get error => _code == 'fr' ? 'Erreur' : 'Error';
  String get noHistory => _code == 'fr' ? 'Aucun historique' : 'No history yet';
  String get noDescription => _code == 'fr' ? 'Sans description' : 'No description';
  String get weightLabel => _code == 'fr' ? 'Poids (g)' : 'Weight (g)';
  String get linkToWeight => _code == 'fr' ? 'Lier les valeurs au poids' : 'Link values to weight';
  String get linkValues => _code == 'fr' ? 'Lier toutes les valeurs ensemble' : 'Link all values together';

  String get dailyIntake => _code == 'fr' ? 'Apport quotidien' : 'Daily Intake';
  String get dailyLimit => _code == 'fr' ? 'Limite quotidienne' : 'Daily limit';
  String get today => _code == 'fr' ? 'Aujourd’hui' : 'Today';
  String get yesterday => _code == 'fr' ? 'Hier' : 'Yesterday';

  // Burned energy + net
  String get burnedTodayTitle => _code == 'fr' ? 'Calories brûlées aujourd’hui' : 'Calories burned today';
  String get refreshBurned => _code == 'fr' ? 'Rafraîchir' : 'Refresh';
  String get burnedLabel => _code == 'fr' ? 'Brûlées' : 'Burned';
  String get burnedNotAvailable => _code == 'fr' ? 'Données non disponibles (autorisez Health Connect)' : 'Data not available (grant Health permissions)';
  String get surplusLabel => _code == 'fr' ? 'Excédent' : 'Surplus';
  String get deficitLabel => _code == 'fr' ? 'Déficit' : 'Deficit';
  String get netKcalLabel => _code == 'fr' ? 'Net' : 'Net';
  String get totalLabel => _code == 'fr' ? 'Total' : 'Total';
  String get activeLabel => _code == 'fr' ? 'Actives' : 'Active';
  String get burnedHelp => _code == 'fr' ? 'Différence Total vs Actives' : 'Total vs Active difference';
  String get burnedHelpText => _code == 'fr'
      ? 'Total = Basal (métabolisme au repos) + Actives (activité). Actives n’inclut pas le métabolisme de base.'
      : 'Total = Basal (resting metabolic) + Active (activity). Active excludes resting metabolic energy.';
  String get ok => _code == 'fr' ? 'OK' : 'OK';

  String get result => _code == 'fr' ? 'Résultat' : 'Result';
  String get copy => _code == 'fr' ? 'Copier' : 'Copy';
  String get copied => _code == 'fr' ? 'Copié dans le presse‑papiers' : 'Copied to clipboard';
  String get debugRaw => _code == 'fr' ? 'Debug brut' : 'Debug raw';
  String get debugRawTitle => _code == 'fr' ? 'Réponse brute' : 'Raw response';
  String get emptyResponse => _code == 'fr' ? 'Réponse vide' : 'Empty response';

  String get mealDetails => _code == 'fr' ? 'Détails du repas' : 'Meal details';
  String get meal => _code == 'fr' ? 'Repas' : 'Meal';
  String get edit => _code == 'fr' ? 'Modifier' : 'Edit';
  String get editMeal => _code == 'fr' ? 'Modifier' : 'Edit'; // from Edit meal to Edit
  String get name => _code == 'fr' ? 'Nom' : 'Name';
  String get kcalLabel => 'Kcal';
  String get carbsLabel => _code == 'fr' ? 'Glucides (g)' : 'Carbs (g)';
  String get proteinLabel => _code == 'fr' ? 'Protéines (g)' : 'Protein (g)';
  String get fatLabel => _code == 'fr' ? 'Lipides (g)' : 'Fat (g)';
  String get cancel => _code == 'fr' ? 'Annuler' : 'Cancel';
  String get save => _code == 'fr' ? 'Enregistrer' : 'Save';
  String get deleteItem => _code == 'fr' ? 'Supprimer l’élément' : 'Delete item';
  String get deleteConfirm => _code == 'fr' ? 'Voulez-vous vraiment supprimer cette entrée ?' : 'Are you sure you want to delete this entry?';
  String get delete => _code == 'fr' ? 'Supprimer' : 'Delete';
  String get mealUpdated => _code == 'fr' ? 'Repas mis à jour' : 'Meal updated';
  String get addManual => _code == 'fr' ? 'Ajouter manuellement' : 'Add manually';
  String get mealBuilderActive => _code == 'fr' ? 'Construction d’un repas en cours' : 'Meal builder active';
  String get finishMeal => _code == 'fr' ? 'Terminer le repas' : 'Finish meal';
  String get restoreDefaults => _code == 'fr' ? 'Restaurer les valeurs par défaut' : 'Restore defaults';
  String get addAnotherQ => _code == 'fr' ? 'Ajouter un autre aliment à ce repas ?' : 'Add another item to this meal?';
  String get addAnother => _code == 'fr' ? 'Ajouter plus' : 'Add more';
  String get notNow => _code == 'fr' ? 'Pas maintenant' : 'Not now';
  String get mealStarted => _code == 'fr' ? 'Nouveau repas en cours. Ajoutez d’autres éléments.' : 'Meal started. Add more items.';
  String itemsInMeal(int n) => _code == 'fr' ? '$n éléments' : '$n items';
  String get remove => _code == 'fr' ? 'Retirer' : 'Remove';
  String get ungroup => _code == 'fr' ? 'Dissocier' : 'Ungroup';
  String groupSummary(int k, int c, int p, int f) => _code == 'fr'
      ? 'Total: ${k} kcal • ${c} g glucides • ${p} g protéines • ${f} g lipides'
      : 'Total: ${k} kcal • ${c} g carbs • ${p} g protein • ${f} g fat';

  // Units/suffixes
  String get kcalSuffix => 'kcal';
  String get carbsSuffix => _code == 'fr' ? 'g glucides' : 'g carbs';
  String get proteinSuffix => _code == 'fr' ? 'g protéines' : 'g protein';
  String get fatSuffix => _code == 'fr' ? 'g lipides' : 'g fat';
  String get packagedFood => _code == 'fr' ? 'Produit emballé' : 'Packaged food';

  // Info menu
  String get info => _code == 'fr' ? 'Infos' : 'Info';
  String get about => _code == 'fr' ? 'À propos' : 'About';
  String versionBuild(String v, String b) => _code == 'fr' ? 'Version $v ($b)' : 'Version $v ($b)';
  String get joinDiscord => _code == 'fr'
    ? 'Pour discuter avec nous ou obtenir de l’aide, rejoignez le Discord'
    : 'To discuss with us or for support, join the discord';
  String get openGithubIssue => _code == 'fr'
    ? 'Pour un problème ou une suggestion, ouvrez un ticket GitHub'
    : 'For issues or suggestions, please open a github issue';
  String get hideForever => _code == 'fr' ? 'Masquer cette annonce' : 'Hide this announcement';
  String get disableAnnouncements => _code == 'fr' ? 'Désactiver les annonces' : 'Disable announcements';
  String get disableAnnouncementsHint => _code == 'fr'
      ? 'Ne jamais afficher les messages d\'administration au démarrage'
      : 'Never show admin messages on startup';
  
  // Queue & notifications
  String get queueAndNotifications => _code == 'fr' ? 'File d\'attente et notifications' : 'Queue & notifications';
  String get backgroundQueue => _code == 'fr' ? 'File d\'attente en arrière-plan' : 'Background queue';
  String get noPendingJobs => _code == 'fr' ? 'Aucune tâche en attente' : 'No pending jobs';
  String get notifications => _code == 'fr' ? 'Notifications' : 'Notifications';
  String get noNotificationsYet => _code == 'fr' ? 'Aucune notification pour l\'instant' : 'No notifications yet';
  String get statusPending => _code == 'fr' ? 'en attente' : 'pending';
  String get statusError => _code == 'fr' ? 'erreur' : 'error';
  String get queueInBackground => _code == 'fr' ? 'Mettre en file d\'attente' : 'Queue in background';
  String get queueInBackgroundHint => _code == 'fr' ? 'Envoyer et continuer. Vous serez notifié quand c\'est prêt.' : 'Send and continue. Get notified when ready.';
  String queuedRequest(String id) => _code == 'fr' ? 'Requête mise en file d\'attente (#$id)' : 'Queued a request (#$id)';
  String get queuedWorking => _code == 'fr' ? 'En file d\'attente : traitement en arrière‑plan' : 'Queued: working in background';
  String get resultSaved => _code == 'fr' ? 'Résultat enregistré dans l\'historique' : 'Result saved to History';
  String get serviceUnavailable => _code == 'fr' ? 'Le service est indisponible, réessayez plus tard.' : 'Service is currently unavailable, please try again later.';

  // Barcode & quantity dialogs
  String get productNotFound => _code == 'fr' ? 'Produit non trouvé' : 'Product not found';
  String get quantityTitle => _code == 'fr' ? 'Quantité (g/ml)' : 'Quantity (g/ml)';
  String quantityHelpDefaultServing(int g) => _code == 'fr'
    ? 'Laissez vide pour la quantité par défaut (${g}g), ou entrez une quantité personnalisée.'
    : 'Leave empty for default quantity (${g}g), or enter a custom amount.';
  String get quantityHelpPackage => _code == 'fr'
    ? 'Laissez vide pour la quantité totale du paquet, ou entrez une quantité personnalisée.'
    : 'Leave empty for full package quantity, or enter a custom amount.';
  String get exampleNumber => _code == 'fr' ? 'Ex: 330' : 'e.g. 330';
  String get scanBarcodeTitle => _code == 'fr' ? 'Scanner le code‑barres' : 'Scan barcode';

  // Auth & account
  String get login => _code == 'fr' ? 'Connexion' : 'Login';
  String get username => _code == 'fr' ? 'Nom d\'utilisateur' : 'Username';
  String get password => _code == 'fr' ? 'Mot de passe' : 'Password';
  String get required => _code == 'fr' ? 'Obligatoire' : 'Required';
  String loginFailedCode(int c) => _code == 'fr' ? 'Échec de connexion ($c)' : 'Login failed ($c)';
  String get loginError => _code == 'fr' ? 'Erreur de connexion' : 'Login error';
  String get noTokenReceived => _code == 'fr' ? 'Aucun jeton reçu' : 'No token received';
  String get networkError => _code == 'fr' ? 'Erreur réseau' : 'Network error';
  String get betaSignup => _code == 'fr' ? 'Pour participer à la bêta, demandez l\'accès.' : 'To sign up for this beta, please request access';
  String get joinDiscordAction => _code == 'fr' ? 'Rejoindre le Discord' : 'Join our Discord';
  String get openDiscordFailed => _code == 'fr' ? 'Impossible d\'ouvrir Discord' : 'Could not open Discord';
  String get logout => _code == 'fr' ? 'Se déconnecter' : 'Log out';

  // Set password
  String get setPasswordTitle => _code == 'fr' ? 'Définir le mot de passe' : 'Set password';
  String get newPassword => _code == 'fr' ? 'Nouveau mot de passe' : 'New password';
  String get confirmPassword => _code == 'fr' ? 'Confirmer le mot de passe' : 'Confirm password';
  String get min6 => _code == 'fr' ? '6 caractères minimum' : 'Min 6 chars';
  String failedWithCode(int c) => _code == 'fr' ? 'Échec ($c)' : 'Failed ($c)';
  String get passwordsDoNotMatch => _code == 'fr' ? 'Les mots de passe ne correspondent pas' : 'Passwords do not match';

  // Export/Import
  String get exportHistory => _code == 'fr' ? 'Exporter l\'historique' : 'Export history';
  String get importHistory => _code == 'fr' ? 'Importer l\'historique' : 'Import history';
  String get exportCanceled => _code == 'fr' ? 'Export annulé' : 'Export canceled';
  String get exportSuccess => _code == 'fr' ? 'Historique exporté' : 'History exported';
  String get exportFailed => _code == 'fr' ? 'Échec de l\'export' : 'Export failed';
  String get confirmImportReplace => _code == 'fr'
      ? 'Importer remplacera votre historique actuel. Continuer ?'
      : 'Import will replace your current history. Continue?';
  String get importSuccess => _code == 'fr' ? 'Historique importé' : 'History imported';
  String get importFailed => _code == 'fr' ? 'Échec de l\'import' : 'Import failed';
}
