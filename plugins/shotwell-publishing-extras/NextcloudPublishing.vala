/* Nextcloud publishing plugin for Shotwell.
 *
 * Uploads the selected photos directly to a remote Nextcloud instance via
 * WebDAV into a folder named after the event, then creates a public link
 * share via the OCS Share API and presents the share URL to the user.
 *
 * This software is licensed under the GNU LGPL (version 2.1 or later).
 * See the COPYING file in this distribution.
 */

public class NextcloudService : Object, Spit.Pluggable, Spit.Publishing.Service {
    private const string ICON_FILENAME = "nextcloud.png";

    private static Gdk.Pixbuf[]? icon_pixbuf_set = null;

    public NextcloudService() {
        if (icon_pixbuf_set == null)
            icon_pixbuf_set = Resources.load_from_resource(Resources.RESOURCE_PATH + "/" +
                ICON_FILENAME);
    }

    public int get_pluggable_interface(int min_host_interface, int max_host_interface) {
        return Spit.negotiate_interfaces(min_host_interface, max_host_interface,
            Spit.Publishing.CURRENT_INTERFACE);
    }

    public unowned string get_id() {
        return "org.gnome.shotwell.publishing.nextcloud";
    }

    public unowned string get_pluggable_name() {
        return _("Nextcloud");
    }

    public void get_info(ref Spit.PluggableInfo info) {
        info.authors = "Shotwell contributors";
        info.copyright = _("Copyright 2026 Shotwell contributors");
        info.translators = Resources.TRANSLATORS;
        info.version = _VERSION;
        info.website_name = _("Visit the Nextcloud web site");
        info.website_url = "https://nextcloud.com/";
        info.is_license_wordwrapped = false;
        info.license = Resources.LICENSE;
        info.icons = icon_pixbuf_set;
    }

    public Spit.Publishing.Publisher create_publisher(Spit.Publishing.PluginHost host) {
        return new Publishing.Nextcloud.NextcloudPublisher(this, host);
    }

    public Spit.Publishing.Publisher.MediaType get_supported_media() {
        return Spit.Publishing.Publisher.MediaType.PHOTO;
    }

    public void activation(bool enabled) {
    }
}

namespace Publishing.Nextcloud {

internal const string SERVICE_NAME = "Nextcloud";

// A public link share as returned by the OCS Share API.
internal class ShareInfo {
    public string id;
    public string url;

    public ShareInfo(string id, string url) {
        this.id = id;
        this.url = url;
    }
}

private const string PASSWORD_SCHEME = "org.gnome.Shotwell.Publishing.Nextcloud";
private const string SCHEMA_KEY_PROFILE_ID = "shotwell-profile-id";

// Config keys (persisted via the host's plugin config store)
private const string CONFIG_SERVER_URL = "server_url";
private const string CONFIG_USER = "nc_user";
private const string CONFIG_REMOTE_BASE = "remote_base";
private const string CONFIG_EXPIRE_DAYS = "expire_days";
private const string CONFIG_SHARE_NOTE = "share_note";
private const string CONFIG_SHARE_PASSWORD = "share_password";

// Alphabet without easily confused characters (no 0/O, 1/l/I)
private const string PW_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789";
private const int PW_LENGTH = 8;

private const string DEFAULT_REMOTE_BASE = "/Photos"; // used when the field is left empty
private const int DEFAULT_EXPIRE_DAYS = 0; // 0 = link never expires
private const int MAX_EXPIRE_DAYS = 3650;
private const string FALLBACK_FOLDER_NAME = "Shotwell";
// Marker prefix of the comment stamp written after sharing. Deliberately NOT
// translated, so the stamp can be recognized again when removing a share.
private const string SHARE_STAMP_PREFIX = "Shared via Nextcloud on ";

public class NextcloudPublisher : Spit.Publishing.Publisher, GLib.Object {
    private weak Spit.Publishing.PluginHost host = null;
    private weak Spit.Publishing.Service service = null;
    private bool running = false;
    private bool cancelled = false;
    private bool login_cancelled = false;
    // set by create_share(): true if an already existing link share was reused
    private bool share_reused = false;
    // remote path of the current/last upload (for the photo comment stamp)
    private string? last_remote_path = null;

    private Secret.Schema schema;
    private Spit.Publishing.ProgressCallback? progress_reporter = null;
    private OptionsPane? pane = null;

    // values currently held by the options pane
    private string server_url;
    private string user;
    private string remote_base;
    private int expire_days;
    private string share_note;
    private string share_password;

    public NextcloudPublisher(Spit.Publishing.Service service, Spit.Publishing.PluginHost host) {
        this.service = service;
        this.host = host;
        this.schema = new Secret.Schema(PASSWORD_SCHEME, Secret.SchemaFlags.NONE,
            SCHEMA_KEY_PROFILE_ID, Secret.SchemaAttributeType.STRING,
            "url", Secret.SchemaAttributeType.STRING,
            "user", Secret.SchemaAttributeType.STRING);

        string? cfg_url = null;
        string? cfg_user = null;
        load_nextcloud_cfg_defaults(out cfg_url, out cfg_user);

        // Note: the config facade maps empty stored strings to null, so coalesce here.
        server_url = host.get_config_string(CONFIG_SERVER_URL, cfg_url ?? "") ?? cfg_url ?? "";
        user = host.get_config_string(CONFIG_USER, cfg_user ?? "") ?? cfg_user ?? "";
        // Leave the field empty if nothing is stored; the default is applied on use.
        remote_base = host.get_config_string(CONFIG_REMOTE_BASE, "") ?? "";
        expire_days = host.get_config_int(CONFIG_EXPIRE_DAYS, DEFAULT_EXPIRE_DAYS);
        share_note = host.get_config_string(CONFIG_SHARE_NOTE, "") ?? "";
        share_password = host.get_config_string(CONFIG_SHARE_PASSWORD, "") ?? "";
    }

    // Generate a random, unambiguous password (no 0/O, 1/l/I) of PW_LENGTH chars.
    internal static string generate_share_password() {
        var sb = new StringBuilder();
        int n = PW_ALPHABET.length;
        for (int i = 0; i < PW_LENGTH; i++)
            sb.append_unichar(PW_ALPHABET.get_char(GLib.Random.int_range(0, n)));
        return sb.str;
    }

    public bool is_running() {
        return running;
    }

    public Spit.Publishing.Service get_service() {
        return service;
    }

    public void start() {
        if (is_running())
            return;

        running = true;
        cancelled = false;

        pane = new OptionsPane(server_url, user, remote_base, lookup_password(),
            expire_days, share_note, share_password);
        pane.action.connect(on_action_clicked);
        pane.browser_login.connect(on_browser_login);
        pane.remote_base_changed.connect(on_remote_base_changed);
        pane.expire_days_changed.connect(on_expire_days_changed);
        pane.share_note_changed.connect(on_share_note_changed);
        pane.share_password_changed.connect(on_share_password_changed);
        update_action_button();
        host.install_dialog_pane(pane);
    }

    private enum ActionMode { PUBLISH, UNPUBLISH, MIXED }
    private ActionMode action_mode = ActionMode.PUBLISH;

    private void on_action_clicked() {
        start_action();
    }

    // One single action button whose label and behavior depend on the share stamps
    // in the comments of the selected photos:
    //  - no photo has a stamp    → "Publish"
    //  - all photos have a stamp → "Unpublish"
    //  - mixed selection         → "Publish/Unpublish" (button stays enabled)
    private void update_action_button() {
        bool any_shared = false;
        bool any_unshared = false;
        foreach (Spit.Publishing.Publishable p in host.get_publishables()) {
            if (has_share_stamp(
                    p.get_param_string(Spit.Publishing.Publishable.PARAM_STRING_COMMENT)))
                any_shared = true;
            else
                any_unshared = true;
        }

        pane.set_status("");
        pane.set_action_sensitive(true);
        if (any_shared && any_unshared) {
            action_mode = ActionMode.MIXED;
            pane.set_action_label("Publish/Unpublish");
        } else if (any_shared) {
            action_mode = ActionMode.UNPUBLISH;
            pane.set_action_label("Unpublish");
        } else {
            action_mode = ActionMode.PUBLISH;
            pane.set_action_label("Publish");
        }
        // Link settings only matter when (also) publishing — grey them out when
        // the selection can only be unpublished.
        pane.set_link_settings_sensitive(action_mode != ActionMode.UNPUBLISH);
    }

    public void stop() {
        running = false;
        cancelled = true;
        login_cancelled = true;
    }

    // Read server URL and user from the Nextcloud desktop client's config, if present,
    // to pre-fill the options pane. Best effort only.
    private static void load_nextcloud_cfg_defaults(out string? url, out string? user) {
        url = null;
        user = null;
        try {
            string path = Environment.get_home_dir() + "/.config/Nextcloud/nextcloud.cfg";
            var kf = new KeyFile();
            kf.load_from_file(path, KeyFileFlags.NONE);
            url = kf.get_string("Accounts", "0\\url");
            user = kf.get_string("Accounts", "0\\dav_user");
        } catch (Error e) {
            debug("No usable Nextcloud desktop config found: %s", e.message);
        }
    }

    internal string? lookup_password() {
        try {
            return Secret.password_lookup_sync(schema, null,
                SCHEMA_KEY_PROFILE_ID, host.get_current_profile_id(),
                "url", server_url, "user", user);
        } catch (Error err) {
            debug("Failed to look up stored Nextcloud app password: %s", err.message);
        }
        return null;
    }

    internal void store_password(string? password) {
        try {
            if (password == null || password == "") {
                Secret.password_clear_sync(schema, null,
                    SCHEMA_KEY_PROFILE_ID, host.get_current_profile_id(),
                    "url", server_url, "user", user);
            } else {
                Secret.password_store_sync(schema, Secret.COLLECTION_DEFAULT,
                    "Shotwell publishing (Nextcloud %s@%s)".printf(user, server_url),
                    password, null,
                    SCHEMA_KEY_PROFILE_ID, host.get_current_profile_id(),
                    "url", server_url, "user", user);
            }
        } catch (Error err) {
            warning("Failed to store Nextcloud app password: %s", err.message);
        }
    }

    // Persist the remote base folder immediately when the user edits it,
    // so it is remembered even if the dialog is cancelled afterwards.
    private void on_remote_base_changed(string value) {
        host.set_config_string(CONFIG_REMOTE_BASE, normalize_remote_base(value));
    }

    private void on_expire_days_changed(int value) {
        host.set_config_int(CONFIG_EXPIRE_DAYS, value);
    }

    private void on_share_note_changed(string value) {
        host.set_config_string(CONFIG_SHARE_NOTE, value);
    }

    private void on_share_password_changed(string value) {
        host.set_config_string(CONFIG_SHARE_PASSWORD, value);
    }

    // Main thread entry point of the single action button. Every selected photo is
    // published or unpublished INDIVIDUALLY, depending on whether its comment has a
    // share stamp. Asks for confirmation first if any photo would be unpublished.
    private void start_action() {
        server_url = pane.get_server_url().strip();
        user = pane.get_user().strip();
        remote_base = normalize_remote_base(pane.get_remote_base().strip());
        expire_days = pane.get_expire_days();
        share_note = pane.get_share_note().strip();
        share_password = pane.get_share_password().strip();
        string password = pane.get_password();

        if (server_url == "" || user == "" || password == "") {
            host.post_error(new Spit.Publishing.PublishingError.SERVICE_ERROR(
                _("Server URL, user name and app password must all be set.")));
            return;
        }

        host.set_config_string(CONFIG_SERVER_URL, server_url);
        host.set_config_string(CONFIG_USER, user);
        host.set_config_string(CONFIG_REMOTE_BASE, remote_base);
        host.set_config_int(CONFIG_EXPIRE_DAYS, expire_days);
        host.set_config_string(CONFIG_SHARE_NOTE, share_note);
        host.set_config_string(CONFIG_SHARE_PASSWORD, share_password);
        store_password(password);

        var publishables = host.get_publishables();
        int shared_count = 0;
        foreach (Spit.Publishing.Publishable p in publishables)
            if (has_share_stamp(p.get_param_string(Spit.Publishing.Publishable.PARAM_STRING_COMMENT)))
                shared_count++;

        // Confirmation only needed when something would be removed from the server.
        if (shared_count > 0) {
            string remote = remote_folder_path(determine_folder_name());
            Gtk.Window? toplevel = pane.get_widget().get_toplevel() as Gtk.Window;
            var dlg = new Gtk.MessageDialog(toplevel, Gtk.DialogFlags.MODAL,
                Gtk.MessageType.WARNING, Gtk.ButtonsType.NONE,
                _("Unpublish the already shared photos?"));
            dlg.format_secondary_text(
                _("%d of the %d selected photo(s) are already shared and will be removed "
                  + "from their server folders (empty folders are deleted on the server, the "
                  + "local share comment is removed). The remaining photo(s) will be published "
                  + "to %s.").printf(shared_count, publishables.length, remote));
            dlg.add_button(_("Cancel"), Gtk.ResponseType.CANCEL);
            dlg.add_button(action_mode == ActionMode.MIXED ? "Publish/Unpublish" : "Unpublish",
                Gtk.ResponseType.YES);
            dlg.set_default_response(Gtk.ResponseType.CANCEL);
            int response = dlg.run();
            dlg.destroy();
            if (response != Gtk.ResponseType.YES)
                return;
        }

        progress_reporter = host.serialize_publishables(0);

        string folder_name = determine_folder_name();
        last_remote_path = remote_folder_path(folder_name);
        debug("Action on Nextcloud folder '%s' at %s", folder_name, server_url);

        host.set_service_locked(true);
        string progress_msg;
        if (action_mode == ActionMode.UNPUBLISH)
            progress_msg = "Unpublishing from Nextcloud";
        else if (action_mode == ActionMode.MIXED)
            progress_msg = "Publishing/Unpublishing to/from Nextcloud";
        else
            progress_msg = "Publishing to Nextcloud";
        host.install_static_message_pane(progress_msg,
            Spit.Publishing.PluginHost.ButtonMode.CANCEL);

        new Thread<void>("nextcloud-action", () => run_action(folder_name, password));
    }

    internal static string normalize_remote_base(string raw) {
        string path = raw;
        if (path == "")
            return DEFAULT_REMOTE_BASE;
        if (!path.has_prefix("/"))
            path = "/" + path;
        while (path.has_suffix("/") && path.length > 1)
            path = path.substring(0, path.length - 1);
        return path;
    }

    // Folder name for publishing: all distinct event names of the selected photos
    // that are NOT yet shared (no share stamp in their comment), comma-separated,
    // so photos from several events land in one folder named "Event A, Event B".
    // Already-shared photos are unpublished individually via their own stamp and do
    // not influence the folder. Fallback: "Shotwell".
    private string determine_folder_name() {
        string[] seen = {};
        var sb = new StringBuilder();
        foreach (Spit.Publishing.Publishable p in host.get_publishables()) {
            if (has_share_stamp(p.get_param_string(Spit.Publishing.Publishable.PARAM_STRING_COMMENT)))
                continue;
            string? event_name = p.get_param_string(Spit.Publishing.Publishable.PARAM_STRING_EVENTNAME);
            if (event_name == null || event_name.strip() == "")
                continue;
            string name = event_name.strip();
            bool duplicate = false;
            foreach (string s in seen) {
                if (s == name) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate)
                continue;
            seen += name;
            if (sb.len > 0)
                sb.append(", ");
            sb.append(name);
        }
        if (sb.len == 0)
            return FALLBACK_FOLDER_NAME;
        return sanitize_folder_name(sb.str);
    }

    // Make a string safe to use as a single path component (also on the server).
    internal static string sanitize_folder_name(string name) {
        string result = name;
        try {
            result = new Regex("[\\\\/:*?\"<>|\\x00-\\x1f]").replace(name, -1, 0, "_");
        } catch (RegexError e) {
            result = name.replace("/", "_");
        }
        result = result.strip();
        if (result == "" || result == "." || result == "..")
            return FALLBACK_FOLDER_NAME;
        if (result.length > 100)
            result = result.substring(0, 100).strip();
        return result;
    }

    // Remove all "Shared via Nextcloud …" stamp blocks from a photo comment,
    // keeping any other (user-written) text.
    internal static string strip_share_stamps(string? comment) {
        if (comment == null || comment == "")
            return "";
        string[] blocks = comment.split("\n\n");
        var kept = new StringBuilder();
        foreach (string block in blocks) {
            if (block.strip().has_prefix(SHARE_STAMP_PREFIX))
                continue;
            if (kept.len > 0)
                kept.append("\n\n");
            kept.append(block);
        }
        return kept.str.strip();
    }

    // True if the comment contains a "Shared via Nextcloud …" share stamp.
    internal static bool has_share_stamp(string? comment) {
        if (comment == null)
            return false;
        foreach (string block in comment.split("\n\n"))
            if (block.strip().has_prefix(SHARE_STAMP_PREFIX))
                return true;
        return false;
    }

    // Extract the remote folder path recorded in a photo's share stamp, e.g.
    // "Shared via Nextcloud on 2026-11-22 01:15 (/Photos/Event A, Event B): …"
    // Returns null if the comment has no share stamp.
    internal static string? extract_stamp_path(string? comment) {
        if (comment == null)
            return null;
        try {
            var re = new Regex("\\((/[^)]+)\\)");
            foreach (string block in comment.split("\n\n")) {
                if (!block.strip().has_prefix(SHARE_STAMP_PREFIX))
                    continue;
                MatchInfo mi;
                if (re.match(block, 0, out mi))
                    return mi.fetch(1);
            }
        } catch (RegexError e) {
            debug("Could not parse share stamp: %s", e.message);
        }
        return null;
    }

    private string dav_root() {
        return "%s/remote.php/dav/files/%s".printf(server_url, enc(user));
    }

    // WebDAV URL for a remote path (e.g. /Photos/Event A, Event B) plus an optional
    // file leaf. Each path segment is percent-encoded, the "/" separators are kept.
    private string dav_url_for_path(string remote_path, string? leaf) {
        var sb = new StringBuilder(dav_root());
        foreach (string segment in remote_path.split("/")) {
            if (segment == "")
                continue;
            sb.append("/");
            sb.append(enc(segment));
        }
        if (leaf != null) {
            sb.append("/");
            sb.append(enc(leaf));
        }
        return sb.str;
    }

    private static string enc(string segment) {
        return Soup.URI.encode(segment, null);
    }

    private string dav_base() {
        return "%s/remote.php/dav/files/%s%s".printf(server_url, enc(user), remote_base);
    }

    private string remote_folder_path(string folder_name) {
        return "%s/%s".printf(remote_base, folder_name);
    }

    private void add_auth(Soup.Message msg, string password) {
        string credentials = "%s:%s".printf(user, password);
        msg.request_headers.append("Authorization",
            "Basic " + Base64.encode(credentials.data));
    }

    private void check_auth_status(Soup.Message msg) throws Spit.Publishing.PublishingError {
        if (msg.status_code == 401 || msg.status_code == 403)
            throw new Spit.Publishing.PublishingError.SERVICE_ERROR(
                _("Authentication failed (HTTP %u). Check user name and app password.").printf(
                    msg.status_code));
    }

    private void mkcol(Soup.Session session, string url, string password)
        throws Spit.Publishing.PublishingError {
        var msg = new Soup.Message("MKCOL", url);
        add_auth(msg, password);
        uint status = session.send_message(msg);
        // 201 = created, 405 = already exists, both fine
        if (status != 201 && status != 405 && status != 200)
            throw new Spit.Publishing.PublishingError.SERVICE_ERROR(
                _("Could not create folder %s (HTTP %u: %s)").printf(
                    url, status, msg.reason_phrase ?? ""));
    }

    private void put_file(Soup.Session session, string url, GLib.File file, string name,
        string password) throws Spit.Publishing.PublishingError {
        uint8[] data;
        try {
            file.load_contents(null, out data, null);
        } catch (Error e) {
            throw new Spit.Publishing.PublishingError.LOCAL_FILE_ERROR(
                _("Could not read %s: %s").printf(name, e.message));
        }

        bool uncertain;
        string content_type = ContentType.guess(name, null, out uncertain);
        if (content_type == "application/octet-stream" || content_type == "text/plain")
            content_type = "image/jpeg";

        var msg = new Soup.Message("PUT", url);
        add_auth(msg, password);
        msg.request_headers.append("Content-Type", content_type);
        msg.set_request(content_type, Soup.MemoryUse.COPY, data);
        uint status = session.send_message(msg);
        check_auth_status(msg);
        if (status != 200 && status != 201 && status != 204)
            throw new Spit.Publishing.PublishingError.SERVICE_ERROR(
                _("Could not upload %s (HTTP %u: %s)").printf(
                    name, status, msg.reason_phrase ?? ""));
    }

    private string expire_date() {
        return new DateTime.now_local().add_days(expire_days).format("%Y-%m-%d");
    }

    // Return the public link share URL for the remote folder. If a public link
    // share already exists for the folder, its URL is returned UNCHANGED: no new
    // share is created and the existing one is NOT modified in any way. A new
    // share is only created when the lookup definitively found none; if the
    // lookup itself fails, an error is thrown instead of risking a duplicate link.
    private string create_share(Soup.Session session, string remote_path, string password)
        throws Spit.Publishing.PublishingError {
        ShareInfo? existing = find_existing_share(session, remote_path, password);
        if (existing != null) {
            share_reused = true;
            debug("Reusing existing link share for %s: %s", remote_path, existing.url);
            return existing.url;
        }
        share_reused = false;

        // Try with the tile-view attribute first; if the server rejects it (older
        // Nextcloud without the attribute), retry once without it. A failed POST
        // does not create a share server-side, so the retry cannot produce a
        // duplicate link.
        string? last_error = null;
        foreach (bool with_tile_view in new bool[] { true, false }) {
            try {
                return post_new_share(session, remote_path, password, with_tile_view);
            } catch (Spit.Publishing.PublishingError.SERVICE_ERROR e) {
                throw e; // e.g. authentication failed — retrying won't help
            } catch (Error e) {
                last_error = e.message;
                debug("Creating share (tile view=%s) failed: %s",
                    with_tile_view.to_string(), e.message);
            }
        }
        throw new Spit.Publishing.PublishingError.SERVICE_ERROR("%s",
            last_error ?? _("Share request failed."));
    }

    // POST a new public link share for remote_path and return its URL. When
    // with_tile_view is true, the share attribute config/grid_view is included so
    // the public link opens in tile (grid) view by default — no dialog input needed.
    private string post_new_share(Soup.Session session, string remote_path, string password,
        bool with_tile_view) throws Spit.Publishing.PublishingError {
        string ocs_url = "%s/ocs/v2.php/apps/files_sharing/api/v1/shares".printf(server_url);
        var body = new StringBuilder("path=%s&shareType=3&permissions=1".printf(enc(remote_path)));
        if (with_tile_view)
            body.append_printf("&attributes=%s",
                enc("[{\"scope\":\"config\",\"key\":\"grid_view\",\"value\":true}]"));
        if (expire_days > 0)
            body.append_printf("&expireDate=%s", enc(expire_date()));
        if (share_note != "")
            body.append_printf("&note=%s", enc(share_note));
        if (share_password != "")
            body.append_printf("&password=%s", enc(share_password));

        var msg = new Soup.Message("POST", ocs_url);
        add_auth(msg, password);
        msg.request_headers.append("OCS-APIRequest", "true");
        msg.request_headers.append("Accept", "application/json");
        msg.request_headers.append("Content-Type", "application/x-www-form-urlencoded");
        msg.set_request("application/x-www-form-urlencoded", Soup.MemoryUse.COPY, body.str.data);
        uint status = session.send_message(msg);
        check_auth_status(msg);
        if (status != 200)
            throw new Spit.Publishing.PublishingError.PROTOCOL_ERROR(
                _("Share request failed (HTTP %u: %s)").printf(status, msg.reason_phrase ?? ""));

        string response = (string) msg.response_body.data;
        string? url = parse_share_url(response);
        if (url != null)
            return url;

        throw new Spit.Publishing.PublishingError.PROTOCOL_ERROR(
            _("Server response did not contain a share URL: %s").printf(response));
    }

    private static string? parse_share_url(string response) {
        try {
            var parser = new Json.Parser();
            parser.load_from_data(response, -1);
            var ocs = parser.get_root().get_object().get_object_member("ocs");
            int statuscode = (int) ocs.get_object_member("meta").get_int_member("statuscode");
            if (statuscode != 200)
                return null;
            return ocs.get_object_member("data").get_string_member("url");
        } catch (Error e) {
            debug("Could not parse OCS response: %s", e.message);
            return null;
        }
    }

    // Look up public link shares (shareType=3) for the given remote path.
    // Returns the first link share found, or null when the server answered 200
    // with an empty list (definitively no link share yet). Throws when the
    // lookup itself failed (non-200, auth error, unparseable response) so the
    // caller can abort instead of creating a duplicate link by accident.
    private ShareInfo? find_existing_share(Soup.Session session, string remote_path,
        string password) throws Spit.Publishing.PublishingError {
        string url = "%s/ocs/v2.php/apps/files_sharing/api/v1/shares?shareType=3&path=%s".printf(
            server_url, enc(remote_path));
        var msg = new Soup.Message("GET", url);
        add_auth(msg, password);
        msg.request_headers.append("OCS-APIRequest", "true");
        msg.request_headers.append("Accept", "application/json");
        uint status = session.send_message(msg);
        check_auth_status(msg);
        if (status != 200)
            throw new Spit.Publishing.PublishingError.SERVICE_ERROR(
                _("Could not check for an existing share on %s (HTTP %u: %s). "
                  + "Aborting so that no duplicate link is created.").printf(
                    remote_path, status, msg.reason_phrase ?? ""));
        try {
            var parser = new Json.Parser();
            parser.load_from_data((string) msg.response_body.data, -1);
            var data = parser.get_root().get_object().get_object_member("ocs")
                .get_member("data").get_array();
            foreach (var element in data.get_elements()) {
                var share = element.get_object();
                // Only accept public link shares (share_type 3), never user/group shares.
                if (share.has_member("share_type") && share.get_int_member("share_type") != 3)
                    continue;
                if (!share.has_member("url"))
                    continue;
                string share_url = share.get_string_member("url");
                if (share_url == "")
                    continue;
                string share_id = share.has_member("id") ? share.get_int_member("id").to_string() : "";
                return new ShareInfo(share_id, share_url);
            }
            return null;
        } catch (Error e) {
            throw new Spit.Publishing.PublishingError.PROTOCOL_ERROR(
                _("Could not parse the share list for %s: %s. "
                  + "Aborting so that no duplicate link is created.").printf(remote_path, e.message));
        }
    }

    // --- Nextcloud Login Flow v2 (browser login, like the desktop client) ---

    private void on_browser_login() {
        server_url = pane.get_server_url().strip();
        if (server_url == "") {
            host.post_error(new Spit.Publishing.PublishingError.SERVICE_ERROR(
                _("Please enter the server URL first.")));
            return;
        }
        host.set_config_string(CONFIG_SERVER_URL, server_url);
        login_cancelled = false;
        pane.set_status(_("Requesting browser login from %s…").printf(server_url));
        new Thread<void>("nextcloud-login", run_browser_login);
    }

    // Runs in a worker thread.
    private void run_browser_login() {
        string? login_url = null;
        string? poll_token = null;
        string? poll_endpoint = null;
        string? login_name = null;
        string? app_password = null;
        string? error_message = null;

        try {
            var session = new Soup.SessionSync();
            session.timeout = 30;

            // Step 1: start a login flow
            var msg = new Soup.Message("POST", "%s/index.php/login/v2".printf(server_url));
            msg.request_headers.append("Accept", "application/json");
            uint status = session.send_message(msg);
            if (status != 200)
                throw new Spit.Publishing.PublishingError.SERVICE_ERROR(
                    _("Could not start browser login (HTTP %u). Is the server URL correct and "
                      + "does the server support the Nextcloud login flow?").printf(status));

            var parser = new Json.Parser();
            parser.load_from_data((string) msg.response_body.data, -1);
            var root = parser.get_root().get_object();
            login_url = root.get_string_member("login");
            var poll = root.get_object_member("poll");
            poll_token = poll.get_string_member("token");
            poll_endpoint = poll.get_string_member("endpoint");

            // Step 2: open the login URL in the user's browser (main thread)
            GLib.Idle.add(() => {
                try {
                    Gtk.show_uri(null, login_url, Gdk.CURRENT_TIME);
                    pane.set_status(_("Please log in and approve “Shotwell” in the browser…"));
                } catch (Error e) {
                    warning("Could not open browser: %s", e.message);
                }
                return false;
            });

            // Step 3: poll until the user approved (404 = pending, 200 = approved)
            for (int i = 0; i < 300 && !login_cancelled; i++) {
                var pmsg = new Soup.Message("POST", poll_endpoint);
                pmsg.request_headers.append("Content-Type", "application/x-www-form-urlencoded");
                pmsg.request_headers.append("Accept", "application/json");
                pmsg.set_request("application/x-www-form-urlencoded", Soup.MemoryUse.COPY,
                    ("token=" + poll_token).data);
                uint pstatus = session.send_message(pmsg);
                if (pstatus == 200) {
                    var presp = new Json.Parser();
                    presp.load_from_data((string) pmsg.response_body.data, -1);
                    var proot = presp.get_root().get_object();
                    login_name = proot.get_string_member("loginName");
                    app_password = proot.get_string_member("appPassword");
                    break;
                } else if (pstatus != 404) {
                    throw new Spit.Publishing.PublishingError.SERVICE_ERROR(
                        _("Login polling failed (HTTP %u).").printf(pstatus));
                }
                Thread.usleep(1000000);
            }
        } catch (Error e) {
            error_message = e.message;
        }

        GLib.Idle.add(() => {
            on_browser_login_finished(login_name, app_password, error_message);
            return false;
        });
    }

    // Runs on the main thread after the browser login flow finished.
    private void on_browser_login_finished(string? login_name, string? app_password,
        string? error_message) {
        if (error_message != null || login_name == null || app_password == null) {
            if (login_cancelled)
                pane.set_status(_("Login cancelled."));
            else
                pane.set_status(_("Browser login failed: %s").printf(
                    error_message ?? _("no credentials received")));
            return;
        }

        user = login_name;
        host.set_config_string(CONFIG_USER, user);
        store_password(app_password);
        pane.set_user(user);
        pane.set_password(app_password);
        pane.set_status(_("Logged in as %s — app password stored in the keyring.").printf(user));
    }

    private void report_progress(int file_number, double fraction) {
        GLib.Idle.add(() => {
            if (progress_reporter != null)
                progress_reporter(file_number, fraction);
            return false;
        });
    }

    // Runs in a worker thread; performs all network I/O synchronously.
    // Each photo is handled INDIVIDUALLY based on its comment:
    //  - share stamp present → unpublish (delete remote file, delete the remote
    //    folder if it becomes empty)
    //  - no stamp            → publish (upload into the event folder, then create or
    //    reuse one public link share for that folder)
    private void run_action(string folder_name, string password) {
        var publishables = host.get_publishables();
        bool[] unpublished = new bool[publishables.length];
        bool[] published = new bool[publishables.length];
        string[] not_found = {};
        int uploaded = 0;
        int unpublished_count = 0;
        int failed = 0;
        string[] touched_folders = {};
        bool any_folder_deleted = false;
        string? share_url = null;
        string? error_message = null;
        share_reused = false;

        try {
            var session = new Soup.SessionSync();
            session.timeout = 300;

            int file_number = 0;

            // --- Phase 1: unpublish every photo that has a share stamp ---
            for (int i = 0; i < publishables.length; i++) {
                if (cancelled)
                    break;
                Spit.Publishing.Publishable p = publishables[i];
                string? comment = p.get_param_string(Spit.Publishing.Publishable.PARAM_STRING_COMMENT);
                if (!has_share_stamp(comment))
                    continue;
                file_number++;
                string name = p.get_param_string(Spit.Publishing.Publishable.PARAM_STRING_BASENAME);
                if (name == null || name == "")
                    name = "photo-%d.jpg".printf(file_number);
                // Delete from the folder recorded in the photo's own share stamp
                // (may be a combined "Event A, Event B" folder); fallback: event folder.
                string? stamp_path = extract_stamp_path(comment);
                string folder_path = stamp_path ?? remote_folder_path(folder_name);
                DeleteResult res = delete_file(session,
                    dav_url_for_path(folder_path, name), password);
                if (res == DeleteResult.DELETED) {
                    unpublished[i] = true;
                    unpublished_count++;
                    if (!(folder_path in touched_folders))
                        touched_folders += folder_path;
                } else if (res == DeleteResult.NOT_FOUND) {
                    not_found += name;
                } else {
                    failed++;
                }
                report_progress(file_number, 1.0);
            }

            // Delete remote folders that became empty.
            if (!cancelled) {
                foreach (string fp in touched_folders) {
                    string furl = dav_url_for_path(fp, null);
                    int children = count_folder_children(session, furl, password);
                    if (children == 0 && delete_folder(session, furl, password))
                        any_folder_deleted = true;
                }
            }

            // --- Phase 2: publish every photo without a share stamp ---
            bool any_unshared = false;
            foreach (Spit.Publishing.Publishable p in publishables)
                if (!has_share_stamp(p.get_param_string(
                        Spit.Publishing.Publishable.PARAM_STRING_COMMENT)))
                    any_unshared = true;

            if (!cancelled && any_unshared) {
                string base_url = dav_base();
                mkcol(session, base_url, password);
                string folder_url = "%s/%s".printf(base_url, enc(folder_name));
                mkcol(session, folder_url, password);

                for (int i = 0; i < publishables.length; i++) {
                    if (cancelled)
                        break;
                    Spit.Publishing.Publishable p = publishables[i];
                    if (has_share_stamp(p.get_param_string(
                            Spit.Publishing.Publishable.PARAM_STRING_COMMENT)))
                        continue;
                    file_number++;
                    GLib.File? file = p.get_serialized_file();
                    if (file == null)
                        continue;
                    string name = p.get_param_string(Spit.Publishing.Publishable.PARAM_STRING_BASENAME);
                    if (name == null || name == "")
                        name = "photo-%d.jpg".printf(file_number);
                    put_file(session, "%s/%s".printf(folder_url, enc(name)), file, name,
                        password);
                    uploaded++;
                    published[i] = true;
                    report_progress(file_number, 1.0);
                }

                if (!cancelled && uploaded > 0)
                    share_url = create_share(session, remote_folder_path(folder_name), password);
            }
        } catch (Error e) {
            error_message = e.message;
        }

        GLib.Idle.add(() => {
            on_action_finished(unpublished, published, uploaded, unpublished_count, failed,
                not_found, any_folder_deleted, folder_name, share_url, error_message);
            return false;
        });
    }

    // Runs on the main thread after the worker finished.
    private void on_action_finished(bool[] unpublished, bool[] published, int uploaded,
        int unpublished_count, int failed, string[] not_found, bool folder_deleted,
        string folder_name, string? share_url, string? error_message) {
        host.set_service_locked(false);

        if (error_message != null) {
            host.post_error(new Spit.Publishing.PublishingError.SERVICE_ERROR("%s", error_message));
            return;
        }

        if (cancelled) {
            host.post_error(new Spit.Publishing.PublishingError.SERVICE_ERROR(
                _("Action was cancelled.")));
            return;
        }

        var publishables = host.get_publishables();

        // Strip the share stamp from the comments of the unpublished photos.
        for (int i = 0; i < publishables.length && i < unpublished.length; i++) {
            if (!unpublished[i])
                continue;
            publishables[i].set_param_string(Spit.Publishing.Publishable.PARAM_STRING_COMMENT,
                strip_share_stamps(
                    publishables[i].get_param_string(Spit.Publishing.Publishable.PARAM_STRING_COMMENT)));
        }

        // Stamp the published photos' comments with link + details (clipboard content).
        if (share_url != null) {
            var clip = new StringBuilder(share_url);
            if (!share_reused) {
                if (expire_days > 0)
                    clip.append_printf("\n%s: %s", _("Valid until"), expire_date());
                if (share_password != "")
                    clip.append_printf("\n%s: %s", _("Password"), share_password);
                if (share_note != "")
                    clip.append_printf("\n%s: %s", _("Note"), share_note);
            }
            try {
                var clipboard = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD);
                clipboard.set_text(clip.str, -1);
                clipboard.store();
            } catch (Error e) {
                debug("Could not copy link to clipboard: %s", e.message);
            }

            string stamp = new DateTime.now_local().format("%Y-%m-%d %H:%M");
            var entry = new StringBuilder();
            entry.append_printf("%s%s", SHARE_STAMP_PREFIX, stamp);
            if (last_remote_path != null)
                entry.append_printf(" (%s)", last_remote_path);
            entry.append_printf(":\n%s", clip.str);
            for (int i = 0; i < publishables.length && i < published.length; i++) {
                if (!published[i])
                    continue;
                string? old = publishables[i].get_param_string(
                    Spit.Publishing.Publishable.PARAM_STRING_COMMENT);
                string new_comment = (old == null || old.strip() == "")
                    ? entry.str
                    : old.strip() + "\n\n" + entry.str;
                publishables[i].set_param_string(Spit.Publishing.Publishable.PARAM_STRING_COMMENT,
                    new_comment);
            }
        }

        // Nothing succeeded at all → error dialog.
        if (uploaded == 0 && unpublished_count == 0 && (not_found.length > 0 || failed > 0)) {
            string msg = not_found.length > 0
                ? _("The following photo(s) were not found on the server and were NOT "
                    + "removed: %s").printf(string.joinv(", ", not_found))
                : _("%d file(s) could not be processed on the server.").printf(failed);
            host.post_error(new Spit.Publishing.PublishingError.SERVICE_ERROR("%s", msg));
            return;
        }

        // Combined result pane.
        var sb = new StringBuilder();
        if (uploaded > 0) {
            sb.append_printf(_("Published %d photo(s) to %s.").printf(
                uploaded, remote_folder_path(folder_name)));
            if (share_url != null) {
                string escaped = GLib.Markup.escape_text(share_url);
                sb.append("\n\n");
                if (share_reused)
                    sb.append(_("The folder already had a public link share — the existing link "
                        + "was reused unchanged (no new link created, nothing overwritten):"));
                else
                    sb.append(_("Share link (copied to the clipboard):"));
                sb.append_printf("\n<a href=\"%s\">%s</a>", escaped, escaped);
                if (!share_reused) {
                    if (expire_days > 0)
                        sb.append_printf("\n%s", _("The link expires on %s.").printf(expire_date()));
                    if (share_note != "")
                        sb.append_printf("\n%s", _("Note for recipients: %s").printf(
                            GLib.Markup.escape_text(share_note)));
                    if (share_password != "")
                        sb.append_printf("\n%s", _("Password: %s").printf(
                            GLib.Markup.escape_text(share_password)));
                }
            }
        }
        if (unpublished_count > 0) {
            if (sb.len > 0)
                sb.append("\n\n");
            sb.append_printf(_("Unpublished %d photo(s): removed from Nextcloud, local share "
                + "comment removed.").printf(unpublished_count));
            if (folder_deleted)
                sb.append_printf("\n%s", _("Empty remote folder(s) were deleted on the server "
                    + "(their share link no longer shows content)."));
        }
        if (not_found.length > 0) {
            if (sb.len > 0)
                sb.append("\n\n");
            sb.append_printf(_("Not found on the server (not removed): %s"),
                GLib.Markup.escape_text(string.joinv(", ", not_found)));
        }
        if (failed > 0) {
            if (sb.len > 0)
                sb.append("\n\n");
            sb.append_printf(_("%d file(s) could not be processed on the server."), failed);
        }
        host.install_pango_message_pane(sb.str, Spit.Publishing.PluginHost.ButtonMode.CLOSE);
    }

    private enum DeleteResult { DELETED, NOT_FOUND, FAILED }

    // DELETE a single file. 404 means the file is NOT in this folder on the server
    // (e.g. combined multi-event folder) — reported as NOT_FOUND so the caller can
    // show an error instead of pretending the photo was removed.
    private DeleteResult delete_file(Soup.Session session, string url, string password)
        throws Spit.Publishing.PublishingError {
        var msg = new Soup.Message("DELETE", url);
        add_auth(msg, password);
        uint status = session.send_message(msg);
        check_auth_status(msg);
        if (status == 200 || status == 204)
            return DeleteResult.DELETED;
        if (status == 404)
            return DeleteResult.NOT_FOUND;
        warning("Could not delete %s (HTTP %u: %s)", url, status, msg.reason_phrase ?? "");
        return DeleteResult.FAILED;
    }

    // DELETE a folder; 404 counts as success.
    private bool delete_folder(Soup.Session session, string url, string password)
        throws Spit.Publishing.PublishingError {
        var msg = new Soup.Message("DELETE", url);
        add_auth(msg, password);
        uint status = session.send_message(msg);
        check_auth_status(msg);
        if (status == 200 || status == 204 || status == 404)
            return true;
        warning("Could not delete folder %s (HTTP %u: %s)", url, status, msg.reason_phrase ?? "");
        return false;
    }

    // PROPFIND Depth:1 on the folder and count the entries; the first <response>
    // is the folder itself, so children = count - 1. 404 → -1 (folder already gone).
    private int count_folder_children(Soup.Session session, string folder_url, string password)
        throws Spit.Publishing.PublishingError {
        var msg = new Soup.Message("PROPFIND", folder_url);
        add_auth(msg, password);
        msg.request_headers.append("Depth", "1");
        msg.request_headers.append("Content-Type", "application/xml; charset=utf-8");
        string propfind_body = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/></d:prop></d:propfind>";
        msg.set_request("application/xml", Soup.MemoryUse.COPY, propfind_body.data);
        uint status = session.send_message(msg);
        check_auth_status(msg);
        if (status == 404)
            return -1;
        if (status != 207)
            throw new Spit.Publishing.PublishingError.SERVICE_ERROR(
                _("Could not list folder %s (HTTP %u: %s)").printf(
                    folder_url, status, msg.reason_phrase ?? ""));

        string body = (string) msg.response_body.data;
        int count = 0;
        try {
            var re = new Regex("<[A-Za-z0-9]*:?response[\\s>]");
            int pos = 0;
            while (true) {
                MatchInfo mi;
                if (!re.match_full(body, -1, pos, 0, out mi))
                    break;
                int start, end;
                mi.fetch_pos(0, out start, out end);
                count++;
                pos = end;
            }
        } catch (RegexError e) {
            throw new Spit.Publishing.PublishingError.PROTOCOL_ERROR(
                _("Could not parse folder listing: %s").printf(e.message));
        }
        return count - 1; // first response element is the folder itself
    }
}

// Options pane: connection settings + publish button, built in code (no .ui resource).
internal class OptionsPane : Spit.Publishing.DialogPane, GLib.Object {
    private Gtk.Box box;
    private Gtk.Entry server_entry;
    private Gtk.Entry user_entry;
    private Gtk.Entry remote_base_entry;
    private Gtk.Entry password_entry;
    private Gtk.Label link_headline;
    private Gtk.Label expire_label;
    private Gtk.SpinButton expire_days_spin;
    private Gtk.Label note_label;
    private Gtk.Entry note_entry;
    private Gtk.Label share_password_label;
    private Gtk.Entry share_password_entry;
    private Gtk.Button regen_button;
    private Gtk.Button browser_login_button;
    private Gtk.Label status_label;
    private Gtk.Button action_button;

    public signal void action();
    public signal void browser_login();
    public signal void remote_base_changed(string value);
    public signal void expire_days_changed(int value);
    public signal void share_note_changed(string value);
    public signal void share_password_changed(string value);

    public OptionsPane(string server_url, string user, string remote_base, string? password,
        int expire_days, string share_note, string share_password) {
        box = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
        box.margin = 12;

        var grid = new Gtk.Grid();
        grid.column_spacing = 6;
        grid.row_spacing = 6;
        box.pack_start(grid, false, false, 0);

        add_headline(grid, 0, _("Server settings"));

        Gtk.Label row_label;
        server_entry = add_row(grid, 1, _("Server URL:"), server_url,
            "https://cloud.example.com", out row_label);

        browser_login_button = new Gtk.Button.with_label(_("Log in via browser…"));
        browser_login_button.clicked.connect(() => browser_login());
        browser_login_button.halign = Gtk.Align.START;
        grid.attach(browser_login_button, 1, 2, 1, 1);

        user_entry = add_row(grid, 3, _("User name:"), user, "user", out row_label);
        password_entry = add_row(grid, 4, _("App password:"), password ?? "",
            _("from browser login or the Nextcloud web UI"), out row_label);
        password_entry.set_visibility(false);

        remote_base_entry = add_row(grid, 5, _("Base folder:"), remote_base,
            DEFAULT_REMOTE_BASE, out row_label);
        remote_base_entry.changed.connect(() =>
            remote_base_changed(remote_base_entry.get_text()));

        link_headline = add_headline(grid, 6, _("Link settings"));

        expire_label = new Gtk.Label(_("Link expires after (days):"));
        expire_label.halign = Gtk.Align.END;
        grid.attach(expire_label, 0, 7, 1, 1);
        expire_days_spin = new Gtk.SpinButton.with_range(0, MAX_EXPIRE_DAYS, 1);
        expire_days_spin.set_value(expire_days);
        expire_days_spin.set_tooltip_text(_("0 = never expires"));
        expire_days_spin.value_changed.connect(() =>
            expire_days_changed((int) expire_days_spin.get_value()));
        grid.attach(expire_days_spin, 1, 7, 1, 1);

        note_entry = add_row(grid, 8, _("Note for recipients:"), share_note,
            _("optional, shown on the public link page"), out note_label);
        note_entry.changed.connect(() => share_note_changed(note_entry.get_text()));

        share_password_entry = add_row(grid, 9, _("Share password:"), share_password,
            _("optional — leave empty for no password"), out share_password_label);
        // Passwords are only generated explicitly via the button, never on focus.
        share_password_entry.changed.connect(() =>
            share_password_changed(share_password_entry.get_text()));

        regen_button = new Gtk.Button.with_label("🔄");
        regen_button.set_tooltip_text(_("Generate a new random password"));
        regen_button.clicked.connect(() =>
            share_password_entry.set_text(NextcloudPublisher.generate_share_password()));
        grid.attach(regen_button, 2, 9, 1, 1);

        status_label = new Gtk.Label("");
        status_label.halign = Gtk.Align.START;
        status_label.set_line_wrap(true);
        box.pack_start(status_label, false, false, 0);

        var hint = new Gtk.Label("The selected photo(s) will be published / unpublished based "
            + "on the associated event(s). For the published photo(s) a public link share will be created "
            + "and copied to the clipboard.");
        hint.set_line_wrap(true);
        hint.halign = Gtk.Align.START;
        box.pack_start(hint, false, false, 6);

        // Single action button; label and behavior are set by the publisher
        // depending on whether the selected photos are already shared.
        action_button = new Gtk.Button.with_label("Publish");
        action_button.clicked.connect(() => action());
        action_button.halign = Gtk.Align.END;
        box.pack_start(action_button, false, false, 6);
    }

    private Gtk.Label add_headline(Gtk.Grid grid, int row, string text) {
        var label = new Gtk.Label("<b>%s</b>".printf(GLib.Markup.escape_text(text)));
        label.use_markup = true;
        label.halign = Gtk.Align.START;
        grid.attach(label, 0, row, 3, 1);
        return label;
    }

    // Grey out the whole "Link settings" block (only relevant when publishing).
    public void set_link_settings_sensitive(bool sensitive) {
        link_headline.set_sensitive(sensitive);
        expire_label.set_sensitive(sensitive);
        expire_days_spin.set_sensitive(sensitive);
        note_label.set_sensitive(sensitive);
        note_entry.set_sensitive(sensitive);
        share_password_label.set_sensitive(sensitive);
        share_password_entry.set_sensitive(sensitive);
        regen_button.set_sensitive(sensitive);
    }

    private Gtk.Entry add_row(Gtk.Grid grid, int row, string label_text, string value,
        string placeholder, out Gtk.Label label) {
        label = new Gtk.Label(label_text);
        label.halign = Gtk.Align.END;
        grid.attach(label, 0, row, 1, 1);
        var entry = new Gtk.Entry();
        entry.set_text(value);
        entry.set_placeholder_text(placeholder);
        entry.hexpand = true;
        grid.attach(entry, 1, row, 1, 1);
        return entry;
    }

    public string get_server_url() {
        return server_entry.get_text();
    }

    public string get_user() {
        return user_entry.get_text();
    }

    public string get_remote_base() {
        return remote_base_entry.get_text();
    }

    public string get_password() {
        return password_entry.get_text();
    }

    public void set_user(string value) {
        user_entry.set_text(value);
    }

    public void set_password(string value) {
        password_entry.set_text(value);
    }

    public void set_status(string text) {
        status_label.set_text(text);
    }

    public void set_action_label(string label) {
        action_button.set_label(label);
    }

    public void set_action_sensitive(bool sensitive) {
        action_button.set_sensitive(sensitive);
    }

    public int get_expire_days() {
        return (int) expire_days_spin.get_value();
    }

    public string get_share_note() {
        return note_entry.get_text();
    }

    public string get_share_password() {
        return share_password_entry.get_text();
    }

    public Gtk.Widget get_widget() {
        return box;
    }

    public Spit.Publishing.DialogPane.GeometryOptions get_preferred_geometry() {
        return Spit.Publishing.DialogPane.GeometryOptions.NONE;
    }

    public void on_pane_installed() {
        action_button.can_default = true;
        action_button.grab_default();
    }

    public void on_pane_uninstalled() {
    }
}

}
