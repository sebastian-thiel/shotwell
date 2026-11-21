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

public class NextcloudPublisher : Spit.Publishing.Publisher, GLib.Object {
    private weak Spit.Publishing.PluginHost host = null;
    private weak Spit.Publishing.Service service = null;
    private bool running = false;
    private bool cancelled = false;
    private bool login_cancelled = false;

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

        string folder_name = determine_folder_name();
        pane = new OptionsPane(server_url, user, remote_base, lookup_password(), folder_name,
            expire_days, share_note, share_password);
        pane.publish.connect(on_publish);
        pane.browser_login.connect(on_browser_login);
        pane.remote_base_changed.connect(on_remote_base_changed);
        pane.expire_days_changed.connect(on_expire_days_changed);
        pane.share_note_changed.connect(on_share_note_changed);
        pane.share_password_changed.connect(on_share_password_changed);
        host.install_dialog_pane(pane);
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

    private void on_publish() {
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

        progress_reporter = host.serialize_publishables(0);

        string folder_name = determine_folder_name();
        debug("Publishing to Nextcloud folder '%s' at %s", folder_name, server_url);

        host.set_service_locked(true);
        host.install_static_message_pane(_("Uploading photos to Nextcloud…"),
            Spit.Publishing.PluginHost.ButtonMode.CANCEL);

        new Thread<void>("nextcloud-upload", () => run_upload(folder_name, password));
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

    // The event name of the first publishable that has one; fallback if the
    // selection has no event.
    private string determine_folder_name() {
        foreach (Spit.Publishing.Publishable p in host.get_publishables()) {
            string? event_name = p.get_param_string(Spit.Publishing.Publishable.PARAM_STRING_EVENTNAME);
            if (event_name != null && event_name.strip() != "")
                return sanitize_folder_name(event_name.strip());
        }
        return FALLBACK_FOLDER_NAME;
    }

    // Make a string safe to use as a single path component (also on the server).
    private static string sanitize_folder_name(string name) {
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

    // Return the public link share URL for the remote folder, reusing an existing
    // link share if there is one (so repeated uploads don't pile up new links),
    // otherwise create a new one. The expiry date / note are applied to both cases.
    private string create_share(Soup.Session session, string remote_path, string password)
        throws Spit.Publishing.PublishingError {
        ShareInfo? existing = find_existing_share(session, remote_path, password);
        if (existing != null) {
            debug("Reusing existing link share for %s: %s", remote_path, existing.url);
            update_share_settings(session, existing.id, password);
            return existing.url;
        }

        string ocs_url = "%s/ocs/v2.php/apps/files_sharing/api/v1/shares".printf(server_url);
        var body = new StringBuilder("path=%s&shareType=3&permissions=1".printf(enc(remote_path)));
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
            throw new Spit.Publishing.PublishingError.SERVICE_ERROR(
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

    private ShareInfo? find_existing_share(Soup.Session session, string remote_path,
        string password) {
        string url = "%s/ocs/v2.php/apps/files_sharing/api/v1/shares?shareType=3&path=%s".printf(
            server_url, enc(remote_path));
        var msg = new Soup.Message("GET", url);
        add_auth(msg, password);
        msg.request_headers.append("OCS-APIRequest", "true");
        msg.request_headers.append("Accept", "application/json");
        uint status = session.send_message(msg);
        if (status != 200)
            return null;
        try {
            var parser = new Json.Parser();
            parser.load_from_data((string) msg.response_body.data, -1);
            var data = parser.get_root().get_object().get_object_member("ocs")
                .get_member("data").get_array();
            foreach (var element in data.get_elements()) {
                var share = element.get_object();
                if (!share.has_member("url"))
                    continue;
                string share_url = share.get_string_member("url");
                if (share_url == "")
                    continue;
                string share_id = share.has_member("id") ? share.get_int_member("id").to_string() : "";
                return new ShareInfo(share_id, share_url);
            }
        } catch (Error e) {
            debug("Could not parse share list: %s", e.message);
        }
        return null;
    }

    // Apply expiry date / note / password to an existing share. Best effort:
    // failures are logged but don't abort the upload.
    private void update_share_settings(Soup.Session session, string share_id, string password) {
        bool want_password = share_password != "";
        if (share_id == "" || (expire_days <= 0 && share_note == "" && !want_password))
            return;

        var body = new StringBuilder();
        if (expire_days > 0)
            body.append_printf("expireDate=%s", enc(expire_date()));
        if (share_note != "") {
            if (body.len > 0)
                body.append("&");
            body.append_printf("note=%s", enc(share_note));
        }
        if (want_password) {
            if (body.len > 0)
                body.append("&");
            body.append_printf("password=%s", enc(share_password));
        }

        string url = "%s/ocs/v2.php/apps/files_sharing/api/v1/shares/%s".printf(
            server_url, enc(share_id));
        var msg = new Soup.Message("PUT", url);
        add_auth(msg, password);
        msg.request_headers.append("OCS-APIRequest", "true");
        msg.request_headers.append("Accept", "application/json");
        msg.request_headers.append("Content-Type", "application/x-www-form-urlencoded");
        msg.set_request("application/x-www-form-urlencoded", Soup.MemoryUse.COPY, body.str.data);
        uint status = session.send_message(msg);
        if (status != 200)
            warning("Could not update settings of share %s (HTTP %u)", share_id, status);
        else
            debug("Updated expiry/note/password of existing share %s", share_id);
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
    private void run_upload(string folder_name, string password) {
        string? share_url = null;
        string? error_message = null;

        try {
            var session = new Soup.SessionSync();
            session.timeout = 300;

            string base_url = dav_base();
            mkcol(session, base_url, password);
            string folder_url = "%s/%s".printf(base_url, enc(folder_name));
            mkcol(session, folder_url, password);

            Spit.Publishing.Publishable[] publishables = host.get_publishables();
            int file_number = 0;
            foreach (Spit.Publishing.Publishable p in publishables) {
                if (cancelled)
                    break;
                file_number++;
                GLib.File? file = p.get_serialized_file();
                if (file == null)
                    continue;
                string name = p.get_param_string(Spit.Publishing.Publishable.PARAM_STRING_BASENAME);
                if (name == null || name == "")
                    name = "photo-%d.jpg".printf(file_number);
                put_file(session, "%s/%s".printf(folder_url, enc(name)), file, name, password);
                report_progress(file_number, 1.0);
            }

            if (!cancelled)
                share_url = create_share(session, remote_folder_path(folder_name), password);
        } catch (Error e) {
            error_message = e.message;
        }

        GLib.Idle.add(() => {
            on_upload_finished(share_url, error_message);
            return false;
        });
    }

    // Runs on the main thread after the worker finished.
    private void on_upload_finished(string? share_url, string? error_message) {
        host.set_service_locked(false);

        if (error_message != null) {
            host.post_error(new Spit.Publishing.PublishingError.SERVICE_ERROR("%s", error_message));
            return;
        }

        if (share_url == null || cancelled) {
            host.post_error(new Spit.Publishing.PublishingError.SERVICE_ERROR(
                _("Upload was cancelled.")));
            return;
        }

        // Offer everything relevant for sharing in the clipboard, not just the URL:
        // link, plus expiry date, password and note if configured.
        var clip = new StringBuilder(share_url);
        if (expire_days > 0)
            clip.append_printf("\n%s: %s", _("Valid until"), expire_date());
        if (share_password != "")
            clip.append_printf("\n%s: %s", _("Password"), share_password);
        if (share_note != "")
            clip.append_printf("\n%s: %s", _("Note"), share_note);
        try {
            var clipboard = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD);
            clipboard.set_text(clip.str, -1);
            clipboard.store();
        } catch (Error e) {
            debug("Could not copy link to clipboard: %s", e.message);
        }

        string escaped = GLib.Markup.escape_text(share_url);
        string markup = _("The photos were uploaded to Nextcloud and the folder was shared.\n\n"
            + "Share link (link, expiry, password and note copied to the clipboard):\n"
            + "<a href=\"%s\">%s</a>").printf(escaped, escaped);
        if (expire_days > 0)
            markup += "\n\n" + _("The link expires on %s.").printf(expire_date());
        if (share_note != "")
            markup += "\n" + _("Note for recipients: %s").printf(
                GLib.Markup.escape_text(share_note));
        if (share_password != "")
            markup += "\n" + _("Password: %s").printf(GLib.Markup.escape_text(share_password));
        host.install_pango_message_pane(markup, Spit.Publishing.PluginHost.ButtonMode.CLOSE);
    }
}

// Options pane: connection settings + publish button, built in code (no .ui resource).
internal class OptionsPane : Spit.Publishing.DialogPane, GLib.Object {
    private Gtk.Box box;
    private Gtk.Entry server_entry;
    private Gtk.Entry user_entry;
    private Gtk.Entry remote_base_entry;
    private Gtk.Entry password_entry;
    private Gtk.SpinButton expire_days_spin;
    private Gtk.Entry note_entry;
    private Gtk.Entry share_password_entry;
    private Gtk.Button browser_login_button;
    private Gtk.Label status_label;
    private Gtk.Label target_label;
    private Gtk.Button publish_button;
    private string folder_name;

    public signal void publish();
    public signal void browser_login();
    public signal void remote_base_changed(string value);
    public signal void expire_days_changed(int value);
    public signal void share_note_changed(string value);
    public signal void share_password_changed(string value);

    public OptionsPane(string server_url, string user, string remote_base, string? password,
        string folder_name, int expire_days, string share_note, string share_password) {
        this.folder_name = folder_name;
        box = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
        box.margin = 12;

        var grid = new Gtk.Grid();
        grid.column_spacing = 6;
        grid.row_spacing = 6;
        box.pack_start(grid, false, false, 0);

        server_entry = add_row(grid, 0, _("Server URL:"), server_url,
            "https://cloud.example.com");

        browser_login_button = new Gtk.Button.with_label(_("Log in via browser…"));
        browser_login_button.clicked.connect(() => browser_login());
        browser_login_button.halign = Gtk.Align.START;
        grid.attach(browser_login_button, 1, 1, 1, 1);

        user_entry = add_row(grid, 2, _("User name:"), user, "user");
        password_entry = add_row(grid, 3, _("App password:"), password ?? "",
            _("from browser login or the Nextcloud web UI"));
        password_entry.set_visibility(false);

        remote_base_entry = add_row(grid, 4, _("Remote folder (base):"), remote_base,
            DEFAULT_REMOTE_BASE);
        remote_base_entry.changed.connect(() => {
            update_target_preview();
            remote_base_changed(remote_base_entry.get_text());
        });

        var expire_label = new Gtk.Label(_("Link expires after (days):"));
        expire_label.halign = Gtk.Align.END;
        grid.attach(expire_label, 0, 5, 1, 1);
        expire_days_spin = new Gtk.SpinButton.with_range(0, MAX_EXPIRE_DAYS, 1);
        expire_days_spin.set_value(expire_days);
        expire_days_spin.set_tooltip_text(_("0 = never expires"));
        expire_days_spin.value_changed.connect(() =>
            expire_days_changed((int) expire_days_spin.get_value()));
        grid.attach(expire_days_spin, 1, 5, 1, 1);

        note_entry = add_row(grid, 6, _("Note for recipients:"), share_note,
            _("optional, shown on the public link page"));
        note_entry.changed.connect(() => share_note_changed(note_entry.get_text()));

        share_password_entry = add_row(grid, 7, _("Share password:"), share_password,
            _("optional — leave empty for no password"));
        // Passwords are only generated explicitly via the button, never on focus.
        share_password_entry.changed.connect(() =>
            share_password_changed(share_password_entry.get_text()));

        var regen_button = new Gtk.Button.with_label("🔄");
        regen_button.set_tooltip_text(_("Generate a new random password"));
        regen_button.clicked.connect(() =>
            share_password_entry.set_text(NextcloudPublisher.generate_share_password()));
        grid.attach(regen_button, 2, 7, 1, 1);

        status_label = new Gtk.Label("");
        status_label.halign = Gtk.Align.START;
        status_label.set_line_wrap(true);
        box.pack_start(status_label, false, false, 0);

        target_label = new Gtk.Label("");
        target_label.halign = Gtk.Align.START;
        target_label.selectable = true;
        box.pack_start(target_label, false, false, 0);
        update_target_preview();

        var hint = new Gtk.Label(_("The selected photos are uploaded into a folder named after "
            + "the event. A public link share is created for that folder and copied to the "
            + "clipboard."));
        hint.set_line_wrap(true);
        hint.halign = Gtk.Align.START;
        box.pack_start(hint, false, false, 6);

        publish_button = new Gtk.Button.with_label(_("Publish"));
        publish_button.clicked.connect(() => publish());
        publish_button.halign = Gtk.Align.END;
        box.pack_start(publish_button, false, false, 6);
    }

    private Gtk.Entry add_row(Gtk.Grid grid, int row, string label_text, string value,
        string placeholder) {
        var label = new Gtk.Label(label_text);
        label.halign = Gtk.Align.END;
        grid.attach(label, 0, row, 1, 1);
        var entry = new Gtk.Entry();
        entry.set_text(value);
        entry.set_placeholder_text(placeholder);
        entry.hexpand = true;
        grid.attach(entry, 1, row, 1, 1);
        return entry;
    }

    private void update_target_preview() {
        target_label.set_text(_("Upload folder on the server: %s/%s").printf(
            NextcloudPublisher.normalize_remote_base(remote_base_entry.get_text()), folder_name));
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
        publish_button.can_default = true;
        publish_button.grab_default();
    }

    public void on_pane_uninstalled() {
    }
}

}
