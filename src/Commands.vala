/* Copyright 2009-2011 Yorba Foundation
 *
 * This software is licensed under the GNU LGPL (version 2.1 or later).
 * See the COPYING file in this distribution. 
 */

// PageCommand stores the current page when a Command is created.  Subclasses can call return_to_page()
// if it's appropriate to return to that page when executing an undo() or redo().
public abstract class PageCommand : Command {
    private Page? page;
    private bool auto_return = true;
    private Photo library_photo = null;
    private CollectionPage collection_page = null;
    
    public PageCommand(string name, string explanation) {
        base (name, explanation);
        
        page = AppWindow.get_instance().get_current_page();
        
        if (page != null) {
            page.destroy.connect(on_page_destroyed);
            
            // If the command occurred on a LibaryPhotoPage, the PageCommand must record additional
            // objects to be restore it to its old state: a specific photo to focus on, a page to return 
            // to, and a view collection to operate over. Note that these objects can be cleared if 
            // the page goes into the background. The required objects are stored below.
            LibraryPhotoPage photo_page = page as LibraryPhotoPage;
            if (photo_page != null) {
                library_photo = photo_page.get_photo();
                collection_page = photo_page.get_controller_page();
                
                if (library_photo != null && collection_page != null) {
                    library_photo.destroyed.connect(on_photo_destroyed);
                    collection_page.destroy.connect(on_controller_destroyed);
                } else {
                    library_photo = null;
                    collection_page = null;
                }
            }
        }
    }
    
    ~PageCommand() {
        if (page != null)
            page.destroy.disconnect(on_page_destroyed);
        
        if (library_photo != null)
            library_photo.destroyed.disconnect(on_photo_destroyed);

        if (collection_page != null)
            collection_page.destroy.disconnect(on_controller_destroyed);
    }
    
    public void set_auto_return_to_page(bool auto_return) {
        this.auto_return = auto_return;
    }
    
    public override void prepare() {
        if (auto_return)
            return_to_page();
        
        base.prepare();
    }
    
    public void return_to_page() {
        LibraryPhotoPage photo_page = page as LibraryPhotoPage;  

        if (photo_page != null) { 
            if (library_photo != null && collection_page != null) {
                bool photo_in_collection = false;
                int count = collection_page.get_view().get_count();
                for (int i = 0; i < count; i++) {
                    if ( ((Thumbnail) collection_page.get_view().get_at(i)).get_media_source() == library_photo) {
                        photo_in_collection = true;
                        break;
                    }
                }
                
                if (photo_in_collection)
                    LibraryWindow.get_app().switch_to_photo_page(collection_page, library_photo);
            }
        } else if (page != null)
            AppWindow.get_instance().set_current_page(page);
    }
    
    private void on_page_destroyed() {
        page.destroy.disconnect(on_page_destroyed);
        page = null;
    }
    
    private void on_photo_destroyed() {
        library_photo.destroyed.disconnect(on_photo_destroyed);
        library_photo = null;
    }

    private void on_controller_destroyed() {
        collection_page.destroy.disconnect(on_controller_destroyed);
        collection_page = null;
    }

}

public abstract class SingleDataSourceCommand : PageCommand {
    protected DataSource source;
    
    public SingleDataSourceCommand(DataSource source, string name, string explanation) {
        base(name, explanation);
        
        this.source = source;
        
        source.destroyed.connect(on_source_destroyed);
    }
    
    ~SingleDataSourceCommand() {
        source.destroyed.disconnect(on_source_destroyed);
    }
    
    public DataSource get_source() {
        return source;
    }
    
    private void on_source_destroyed() {
        // too much risk in simply removing this from the CommandManager; if this is considered too
        // broad a brushstroke, can return to this later
        get_command_manager().reset();
    }
}

public abstract class SimpleProxyableCommand : PageCommand {
    private SourceProxy proxy;
    
    public SimpleProxyableCommand(Proxyable proxyable, string name, string explanation) {
        base (name, explanation);
        
        proxy = proxyable.get_proxy();
        proxy.broken.connect(on_proxy_broken);
    }
    
    ~SimpleProxyableCommand() {
        proxy.broken.disconnect(on_proxy_broken);
    }
    
    public override void execute() {
        execute_on_source(proxy.get_source());
    }
    
    protected abstract void execute_on_source(DataSource source);
    
    public override void undo() {
        undo_on_source(proxy.get_source());
    }
    
    protected abstract void undo_on_source(DataSource source);
    
    private void on_proxy_broken() {
        get_command_manager().reset();
    }
}

public abstract class SinglePhotoTransformationCommand : SingleDataSourceCommand {
    private PhotoTransformationState state;
    
    public SinglePhotoTransformationCommand(Photo photo, string name, string explanation) {
        base(photo, name, explanation);
        
        state = photo.save_transformation_state();
        state.broken.connect(on_state_broken);
    }
    
    ~SinglePhotoTransformationCommand() {
        state.broken.disconnect(on_state_broken);
    }
    
    public override void undo() {
        ((Photo) source).load_transformation_state(state);
    }
    
    private void on_state_broken() {
        get_command_manager().reset();
    }
}

public abstract class GenericPhotoTransformationCommand : SingleDataSourceCommand {
    private PhotoTransformationState original_state = null;
    private PhotoTransformationState transformed_state = null;
    
    public GenericPhotoTransformationCommand(Photo photo, string name, string explanation) {
        base(photo, name, explanation);
    }
    
    ~GenericPhotoTransformationState() {
        if (original_state != null)
            original_state.broken.disconnect(on_state_broken);
        
        if (transformed_state != null)
            transformed_state.broken.disconnect(on_state_broken);
    }
    
    public override void execute() {
        Photo photo = (Photo) source;
        
        original_state = photo.save_transformation_state();
        original_state.broken.connect(on_state_broken);
        
        execute_on_photo(photo);
        
        transformed_state = photo.save_transformation_state();
        transformed_state.broken.connect(on_state_broken);
    }
    
    public abstract void execute_on_photo(Photo photo);
    
    public override void undo() {
        // use the original state of the photo
        ((Photo) source).load_transformation_state(original_state);
    }
    
    public override void redo() {
        // use the state of the photo after transformation
        ((Photo) source).load_transformation_state(transformed_state);
    }
    
    protected virtual bool can_compress(Command command) {
        return false;
    }
    
    public override bool compress(Command command) {
        if (!can_compress(command))
            return false;
        
        GenericPhotoTransformationCommand generic = command as GenericPhotoTransformationCommand;
        if (generic == null)
            return false;
        
        if (generic.source != source)
            return false;
        
        // execute this new (and successive) command
        generic.execute();
        
        // save it's new transformation state as ours
        transformed_state = generic.transformed_state;
        
        return true;
    }
    
    private void on_state_broken() {
        get_command_manager().reset();
    }
}

public abstract class MultipleDataSourceCommand : PageCommand {
    protected const int MIN_OPS_FOR_PROGRESS_WINDOW = 5;
    
    protected Gee.ArrayList<DataSource> source_list = new Gee.ArrayList<DataSource>();
    
    private string progress_text;
    private string undo_progress_text;
    private Gee.ArrayList<DataSource> acted_upon = new Gee.ArrayList<DataSource>();
    private Gee.HashSet<SourceCollection> hooked_collections = new Gee.HashSet<SourceCollection>();
    
    public MultipleDataSourceCommand(Gee.Iterable<DataView> iter, string progress_text,
        string undo_progress_text, string name, string explanation) {
        base(name, explanation);
        
        this.progress_text = progress_text;
        this.undo_progress_text = undo_progress_text;
        
        foreach (DataView view in iter) {
            DataSource source = view.get_source();
            SourceCollection? collection = (SourceCollection) source.get_membership();
    
            if (collection != null) {
                hooked_collections.add(collection);
            }
            source_list.add(source);
        }
        
        foreach (SourceCollection current_collection in hooked_collections) {
            current_collection.item_destroyed.connect(on_source_destroyed);
        }
    }
    
    ~MultipleDataSourceCommand() {
        foreach (SourceCollection current_collection in hooked_collections) {
            current_collection.item_destroyed.disconnect(on_source_destroyed);
        }
    }
    
    public Gee.Iterable<DataSource> get_sources() {
        return source_list;
    }
    
    public int get_source_count() {
        return source_list.size;
    }
    
    private void on_source_destroyed(DataSource source) {
        // as with SingleDataSourceCommand, too risky to selectively remove commands from the stack,
        // although this could be reconsidered in the future
        if (source_list.contains(source))
            get_command_manager().reset();
    }
    
    public override void execute() {
        acted_upon.clear();
        
        start_transaction();
        execute_all(true, true, source_list, acted_upon);
        commit_transaction();
    }
    
    public abstract void execute_on_source(DataSource source);
    
    public override void undo() {
        if (acted_upon.size > 0) {
            start_transaction();
            execute_all(false, false, acted_upon, null);
            commit_transaction();
            
            acted_upon.clear();
        }
    }
    
    public abstract void undo_on_source(DataSource source);
    
    private void start_transaction() {
        foreach (SourceCollection sources in hooked_collections) {
            MediaSourceCollection? media_collection = sources as MediaSourceCollection;
            if (media_collection != null)
                media_collection.transaction_controller.begin();
        }
    }
    
    private void commit_transaction() {
        foreach (SourceCollection sources in hooked_collections) {
            MediaSourceCollection? media_collection = sources as MediaSourceCollection;
            if (media_collection != null)
                media_collection.transaction_controller.commit();
        }
    }
    
    private void execute_all(bool exec, bool can_cancel, Gee.ArrayList<DataSource> todo, 
        Gee.ArrayList<DataSource>? completed) {
        AppWindow.get_instance().set_busy_cursor();
        
        int count = 0;
        int total = todo.size;
        int two_percent = (int) ((double) total / 50.0);
        if (two_percent <= 0)
            two_percent = 1;
        
        string text = exec ? progress_text : undo_progress_text;
        
        Cancellable cancellable = null;
        ProgressDialog progress = null;
        if (total >= MIN_OPS_FOR_PROGRESS_WINDOW) {
            cancellable = can_cancel ? new Cancellable() : null;
            progress = new ProgressDialog(AppWindow.get_instance(), text, cancellable);
        }
        
        foreach (DataSource source in todo) {
            if (exec)
                execute_on_source(source);
            else
                undo_on_source(source);
            
            if (completed != null)
                completed.add(source);

            if (progress != null) {
                if ((++count % two_percent) == 0) {
                    progress.set_fraction(count, total);
                    spin_event_loop();
                }
                
                if (cancellable != null && cancellable.is_cancelled())
                    break;
            }
        }
        
        if (progress != null)
            progress.close();
        
        AppWindow.get_instance().set_normal_cursor();
    }
}

// TODO: Upgrade MultipleDataSourceAtOnceCommand to use TransactionControllers.
public abstract class MultipleDataSourceAtOnceCommand : PageCommand {
    private Gee.HashSet<DataSource> sources = new Gee.HashSet<DataSource>();
    private Gee.HashSet<SourceCollection> hooked_collections = new Gee.HashSet<SourceCollection>();
    
    public MultipleDataSourceAtOnceCommand(Gee.Collection<DataSource> sources, string name,
        string explanation) {
        base (name, explanation);
        
        this.sources.add_all(sources);
        
        foreach (DataSource source in this.sources) {
            SourceCollection? membership = source.get_membership() as SourceCollection;
            if (membership != null)
                hooked_collections.add(membership);
        }
        
        foreach (SourceCollection source_collection in hooked_collections)
            source_collection.items_destroyed.connect(on_sources_destroyed);
    }
    
    ~MultipleDataSourceAtOnceCommand() {
        foreach (SourceCollection source_collection in hooked_collections)
            source_collection.items_destroyed.disconnect(on_sources_destroyed);
    }
    
    public override void execute() {
        AppWindow.get_instance().set_busy_cursor();
        
        DatabaseTable.begin_transaction();
        MediaCollectionRegistry.get_instance().freeze_all();
        
        execute_on_all(sources);
        
        MediaCollectionRegistry.get_instance().thaw_all();
        try {
            DatabaseTable.commit_transaction();
        } catch (DatabaseError err) {
            AppWindow.database_error(err);
        } finally {
            AppWindow.get_instance().set_normal_cursor();
        }
    }
    
    protected abstract void execute_on_all(Gee.Collection<DataSource> sources);
    
    public override void undo() {
        AppWindow.get_instance().set_busy_cursor();
        
        DatabaseTable.begin_transaction();
        MediaCollectionRegistry.get_instance().freeze_all();
        
        undo_on_all(sources);
        
        MediaCollectionRegistry.get_instance().thaw_all();
        try {
            DatabaseTable.commit_transaction();
        } catch (DatabaseError err) {
            AppWindow.database_error(err);
        } finally {
            AppWindow.get_instance().set_normal_cursor();
        }
    }
    
    protected abstract void undo_on_all(Gee.Collection<DataSource> sources);
    
    private void on_sources_destroyed(Gee.Collection<DataSource> destroyed) {
        foreach (DataSource source in destroyed) {
            if (sources.contains(source)) {
                get_command_manager().reset();
                
                break;
            }
        }
    }
}

public abstract class MultiplePhotoTransformationCommand : MultipleDataSourceCommand {
    private Gee.HashMap<Photo, PhotoTransformationState> map = new Gee.HashMap<
        Photo, PhotoTransformationState>();
    
    public MultiplePhotoTransformationCommand(Gee.Iterable<DataView> iter, string progress_text,
        string undo_progress_text, string name, string explanation) {
        base(iter, progress_text, undo_progress_text, name, explanation);
        
        foreach (DataSource source in source_list) {
            Photo photo = (Photo) source;
            PhotoTransformationState state = photo.save_transformation_state();
            state.broken.connect(on_state_broken);
            
            map.set(photo, state);
        }
    }
    
    ~MultiplePhotoTransformationCommand() {
        foreach (PhotoTransformationState state in map.values)
            state.broken.disconnect(on_state_broken);
    }
    
    public override void undo_on_source(DataSource source) {
        Photo photo = (Photo) source;
        
        PhotoTransformationState state = map.get(photo);
        assert(state != null);
        
        photo.load_transformation_state(state);
    }
    
    private void on_state_broken() {
        get_command_manager().reset();
    }
}

public class RotateSingleCommand : SingleDataSourceCommand {
    private Rotation rotation;
    
    public RotateSingleCommand(Photo photo, Rotation rotation, string name, string explanation) {
        base(photo, name, explanation);
        
        this.rotation = rotation;
    }
    
    public override void execute() {
        ((Photo) source).rotate(rotation);
    }
    
    public override void undo() {
        ((Photo) source).rotate(rotation.opposite());
    }
}

public class RotateMultipleCommand : MultipleDataSourceCommand {
    private Rotation rotation;
    
    public RotateMultipleCommand(Gee.Iterable<DataView> iter, Rotation rotation, string name, 
        string explanation, string progress_text, string undo_progress_text) {
        base(iter, progress_text, undo_progress_text, name, explanation);
        
        this.rotation = rotation;
    }
    
    public override void execute_on_source(DataSource source) {
        ((Photo) source).rotate(rotation);
    }
    
    public override void undo_on_source(DataSource source) {
        ((Photo) source).rotate(rotation.opposite());
    }
}

public class EditTitleCommand : SingleDataSourceCommand {
    private string new_title;
    private string? old_title;
    
    public EditTitleCommand(MediaSource source, string new_title) {
        base(source, Resources.EDIT_TITLE_LABEL, "");
        
        this.new_title = new_title;
        old_title = source.get_title();
    }
    
    public override void execute() {
        ((MediaSource) source).set_title(new_title);
    }
    
    public override void undo() {
        ((MediaSource) source).set_title(old_title);
    }
}

public class EditMultipleTitlesCommand : MultipleDataSourceAtOnceCommand {
    public string new_title;
    public Gee.HashMap<MediaSource, string?> old_titles = new Gee.HashMap<MediaSource, string?>();
    
    public EditMultipleTitlesCommand(Gee.Collection<MediaSource> media_sources, string new_title) {
        base (media_sources, Resources.EDIT_TITLE_LABEL, "");
        
        this.new_title = new_title;
        foreach (MediaSource media in media_sources)
            old_titles.set(media, media.get_title());
    }
    
    public override void execute_on_all(Gee.Collection<DataSource> sources) {
        foreach (DataSource source in sources)
            ((MediaSource) source).set_title(new_title);
    }
    
    public override void undo_on_all(Gee.Collection<DataSource> sources) {
        foreach (DataSource source in sources)
            ((MediaSource) source).set_title(old_titles.get((MediaSource) source));
    }
}

public class RenameEventCommand : SimpleProxyableCommand {
    private string new_name;
    private string? old_name;
    
    public RenameEventCommand(Event event, string new_name) {
        base(event, Resources.RENAME_EVENT_LABEL, "");
        
        this.new_name = new_name;
        old_name = event.get_raw_name();
    }
    
    public override void execute_on_source(DataSource source) {
        ((Event) source).rename(new_name);
    }
    
    public override void undo_on_source(DataSource source) {
        ((Event) source).rename(old_name);
    }
}

public class SetKeyPhotoCommand : SingleDataSourceCommand {
    private MediaSource new_primary_source;
    private MediaSource old_primary_source;
    
    public SetKeyPhotoCommand(Event event, MediaSource new_primary_source) {
        base(event, Resources.MAKE_KEY_PHOTO_LABEL, "");
        
        this.new_primary_source = new_primary_source;
        old_primary_source = event.get_primary_source();
    }
    
    public override void execute() {
        ((Event) source).set_primary_source(new_primary_source);
    }
    
    public override void undo() {
        ((Event) source).set_primary_source(old_primary_source);
    }
}

public class RevertSingleCommand : GenericPhotoTransformationCommand {
    public RevertSingleCommand(Photo photo) {
        base(photo, Resources.REVERT_LABEL, "");
    }
    
    public override void execute_on_photo(Photo photo) {
        photo.remove_all_transformations();
    }
    
    public override bool compress(Command command) {
        RevertSingleCommand revert_single_command = command as RevertSingleCommand;
        if (revert_single_command == null)
            return false;
        
        if (revert_single_command.source != source)
            return false;
        
        // no need to execute anything; multiple successive reverts on the same photo are as good
        // as one
        return true;
    }
}

public class RevertMultipleCommand : MultiplePhotoTransformationCommand {
    public RevertMultipleCommand(Gee.Iterable<DataView> iter) {
        base(iter, _("Reverting"), _("Undoing Revert"), Resources.REVERT_LABEL,
            "");
    }
    
    public override void execute_on_source(DataSource source) {
        ((Photo) source).remove_all_transformations();
    }
}

public class EnhanceSingleCommand : GenericPhotoTransformationCommand {
    public EnhanceSingleCommand(Photo photo) {
        base(photo, Resources.ENHANCE_LABEL, Resources.ENHANCE_TOOLTIP);
    }
    
    public override void execute_on_photo(Photo photo) {
        AppWindow.get_instance().set_busy_cursor();
#if MEASURE_ENHANCE
        Timer overall_timer = new Timer();
#endif
        
        photo.enhance();
        
#if MEASURE_ENHANCE
        overall_timer.stop();
        debug("Auto-Enhance overall time: %f sec", overall_timer.elapsed());
#endif
        AppWindow.get_instance().set_normal_cursor();
    }
    
    public override bool compress(Command command) {
        EnhanceSingleCommand enhance_single_command = command as EnhanceSingleCommand;
        if (enhance_single_command == null)
            return false;
        
        if (enhance_single_command.source != source)
            return false;
        
        // multiple successive enhances on the same photo are as good as a single
        return true;
    }
}

public class EnhanceMultipleCommand : MultiplePhotoTransformationCommand {
    public EnhanceMultipleCommand(Gee.Iterable<DataView> iter) {
        base(iter, _("Enhancing"), _("Undoing Enhance"), Resources.ENHANCE_LABEL,
            Resources.ENHANCE_TOOLTIP);
    }
    
    public override void execute_on_source(DataSource source) {
        ((Photo) source).enhance();
    }
}

public class StraightenCommand : GenericPhotoTransformationCommand {
    private double theta;
    
    public StraightenCommand(Photo photo, double theta, string name, string explanation) {
        base(photo, name, explanation);
        
        this.theta = theta;
    }
    
    public override void execute_on_photo(Photo photo) {
        photo.set_straighten(theta);
    }
}

public class CropCommand : GenericPhotoTransformationCommand {
    private Box crop;
    
    public CropCommand(Photo photo, Box crop, string name, string explanation) {
        base(photo, name, explanation);
        
        this.crop = crop;
    }
    
    public override void execute_on_photo(Photo photo) {
        photo.set_crop(crop);
    }
}

public class AdjustColorsCommand : GenericPhotoTransformationCommand {
    private PixelTransformationBundle transformations;
    
    public AdjustColorsCommand(Photo photo, PixelTransformationBundle transformations,
        string name, string explanation) {
        base(photo, name, explanation);
        
        this.transformations = transformations;
    }
    
    public override void execute_on_photo(Photo photo) {
        AppWindow.get_instance().set_busy_cursor();
        
        photo.set_color_adjustments(transformations);
        
        AppWindow.get_instance().set_normal_cursor();
    }
    
    public override bool can_compress(Command command) {
        return command is AdjustColorsCommand;
    }
}

public class RedeyeCommand : GenericPhotoTransformationCommand {
    private RedeyeInstance redeye_instance;
    
    public RedeyeCommand(Photo photo, RedeyeInstance redeye_instance, string name,
        string explanation) {
        base(photo, name, explanation);
        
        this.redeye_instance = redeye_instance;
    }
    
    public override void execute_on_photo(Photo photo) {
        photo.add_redeye_instance(redeye_instance);
    }
}

public abstract class MovePhotosCommand : Command {
    // Piggyback on a private command so that processing to determine new_event can occur before
    // contruction, if needed
    protected class RealMovePhotosCommand : MultipleDataSourceCommand {
        private SourceProxy new_event_proxy = null;
        private Gee.HashMap<MediaSource, SourceProxy?> old_events = new Gee.HashMap<
            MediaSource, SourceProxy?>();
        
        public RealMovePhotosCommand(Event? new_event, Gee.Iterable<DataView> source_views,
            string progress_text, string undo_progress_text, string name, string explanation) {
            base(source_views, progress_text, undo_progress_text, name, explanation);
            
            // get proxies for each media source's event
            foreach (DataSource source in source_list) {
                MediaSource current_media = (MediaSource) source;
                Event? old_event = current_media.get_event();
                SourceProxy? old_event_proxy = (old_event != null) ? old_event.get_proxy() : null;
                
                // if any of the proxies break, the show's off
                if (old_event_proxy != null)
                    old_event_proxy.broken.connect(on_proxy_broken);
                
                old_events.set(current_media, old_event_proxy);
            }
            
            // stash the proxy of the new event
            new_event_proxy = new_event.get_proxy();
            new_event_proxy.broken.connect(on_proxy_broken);
        }
        
        ~RealMovePhotosCommand() {
            new_event_proxy.broken.disconnect(on_proxy_broken);
            
            foreach (SourceProxy? proxy in old_events.values) {
                if (proxy != null)
                    proxy.broken.disconnect(on_proxy_broken);
            }
        }
        
        public override void execute() {
            // switch to new event page first (to prevent flicker if other pages are destroyed)
            LibraryWindow.get_app().switch_to_event((Event) new_event_proxy.get_source());
            
            // create the new event
            base.execute();
        }
        
        public override void execute_on_source(DataSource source) {
            ((MediaSource) source).set_event((Event?) new_event_proxy.get_source());
        }
        
        public override void undo_on_source(DataSource source) {
            MediaSource current_media = (MediaSource) source;
            SourceProxy? event_proxy = old_events.get(current_media);
            
            current_media.set_event(event_proxy != null ? (Event?) event_proxy.get_source() : null);
        }
        
        private void on_proxy_broken() {
            get_command_manager().reset();
        }
    }

    protected RealMovePhotosCommand real_command;
    
    public MovePhotosCommand(string name, string explanation) {
        base(name, explanation);
    }
    
    public override void prepare() {
        assert(real_command != null);
        real_command.prepare();
    }
    
    public override void execute() {
        assert(real_command != null);
        real_command.execute();
    }
    
    public override void undo() {
        assert(real_command != null);
        real_command.undo();
    }
}

public class NewEventCommand : MovePhotosCommand {
    public NewEventCommand(Gee.Iterable<DataView> iter) {
        base(Resources.NEW_EVENT_LABEL, "");

        // get the primary or "key" source for the new event (which is simply the first one)
        MediaSource key_source = null;
        foreach (DataView view in iter) {
            MediaSource current_source = (MediaSource) view.get_source();
            
            if (key_source == null) {
                key_source = current_source;
                break;
            }
        }
        
        // key photo is required for an event
        assert(key_source != null);

        Event new_event = Event.create_empty_event(key_source);

        real_command = new RealMovePhotosCommand(new_event, iter, _("Creating New Event"),
            _("Removing Event"), Resources.NEW_EVENT_LABEL,
            "");
    }
}

public class SetEventCommand : MovePhotosCommand {
    public SetEventCommand(Gee.Iterable<DataView> iter, Event new_event) {
        base(Resources.SET_PHOTO_EVENT_LABEL, Resources.SET_PHOTO_EVENT_TOOLTIP);

        real_command = new RealMovePhotosCommand(new_event, iter, _("Moving Photos to New Event"),
            _("Setting Photos to Previous Event"), Resources.SET_PHOTO_EVENT_LABEL, 
            "");
    }
}

public class MergeEventsCommand : MovePhotosCommand {
    public MergeEventsCommand(Gee.Iterable<DataView> iter) {
        base (Resources.MERGE_LABEL, "");
        
        // the master event is the first one found with a name, otherwise the first one in the lot
        Event master_event = null;
        Gee.ArrayList<ThumbnailView> media_thumbs = new Gee.ArrayList<ThumbnailView>();
        
        foreach (DataView view in iter) {
            Event event = (Event) view.get_source();
            
            if (master_event == null)
                master_event = event;
            else if (!master_event.has_name() && event.has_name())
                master_event = event;
            
            // store all media sources in this operation; they will be moved to the master event
            // (keep proxies of their original event for undo)
            foreach (MediaSource media_source in event.get_media())
                media_thumbs.add(new ThumbnailView(media_source));
        }
        
        assert(master_event != null);
        assert(media_thumbs.size > 0);
        
        real_command = new RealMovePhotosCommand(master_event, media_thumbs, _("Merging"), 
            _("Unmerging"), Resources.MERGE_LABEL, "");
    }
}

public class DuplicateMultiplePhotosCommand : MultipleDataSourceCommand {
    private Gee.HashMap<LibraryPhoto, LibraryPhoto> dupes = new Gee.HashMap<LibraryPhoto, LibraryPhoto>();
    private int failed = 0;
    
    public DuplicateMultiplePhotosCommand(Gee.Iterable<DataView> iter) {
        base (iter, _("Duplicating photos"), _("Removing duplicated photos"), 
            Resources.DUPLICATE_PHOTO_LABEL, Resources.DUPLICATE_PHOTO_TOOLTIP);
        
        LibraryPhoto.global.item_destroyed.connect(on_photo_destroyed);
    }
    
    ~DuplicateMultiplePhotosCommand() {
        LibraryPhoto.global.item_destroyed.disconnect(on_photo_destroyed);
    }
    
    private void on_photo_destroyed(DataSource source) {
        // if one of the duplicates is destroyed, can no longer undo it (which destroys it again)
        if (dupes.values.contains((LibraryPhoto) source))
            get_command_manager().reset();
    }
    
    public override void execute() {
        dupes.clear();
        failed = 0;
        
        base.execute();
        
        if (failed > 0) {
            string error_string = (ngettext("Unable to duplicate one photo due to a file error",
                "Unable to duplicate %d photos due to file errors", failed)).printf(failed);
            AppWindow.error_message(error_string);
        }
    }
    
    public override void execute_on_source(DataSource source) {
        LibraryPhoto photo = (LibraryPhoto) source;
        
        try {
            LibraryPhoto dupe = photo.duplicate();
            dupes.set(photo, dupe);
        } catch (Error err) {
            critical("Unable to duplicate file %s: %s", photo.get_file().get_path(), err.message);
            failed++;
        }
    }
    
    public override void undo() {
        // disconnect from monitoring the duplicates' destruction, as undo() does exactly that
        LibraryPhoto.global.item_destroyed.disconnect(on_photo_destroyed);
        
        base.undo();
        
        // be sure to drop everything that was destroyed
        dupes.clear();
        failed = 0;
        
        // re-monitor for duplicates' destruction
        LibraryPhoto.global.item_destroyed.connect(on_photo_destroyed);
    }
    
    public override void undo_on_source(DataSource source) {
        LibraryPhoto photo = (LibraryPhoto) source;
        
        Marker marker = LibraryPhoto.global.mark(dupes.get(photo));
        LibraryPhoto.global.destroy_marked(marker, true);
    }
}

public class SetRatingSingleCommand : SingleDataSourceCommand {
    private Rating last_rating;
    private Rating new_rating;
    private bool set_direct;
    private bool incrementing;

    public SetRatingSingleCommand(DataSource source, Rating rating) {
        base (source, Resources.rating_label(rating), "");
        set_direct = true;
        new_rating = rating;

        last_rating = ((LibraryPhoto)source).get_rating();
    }

    public SetRatingSingleCommand.inc_dec(DataSource source, bool is_incrementing) {
        base (source, is_incrementing ? Resources.INCREASE_RATING_LABEL : 
            Resources.DECREASE_RATING_LABEL, "");
        set_direct = false;
        incrementing = is_incrementing;

        last_rating = ((MediaSource) source).get_rating();
    }

    public override void execute() {
        if (set_direct)
            ((MediaSource) source).set_rating(new_rating);
        else {
            if (incrementing) 
                ((MediaSource) source).increase_rating();
            else
                ((MediaSource) source).decrease_rating();
        }
    }
    
    public override void undo() {
        ((MediaSource) source).set_rating(last_rating);
    }
}

public class SetRatingCommand : MultipleDataSourceCommand {
    private Gee.HashMap<DataSource, Rating> last_rating_map;
    private Rating new_rating;
    private bool set_direct;
    private bool incrementing;
    private int action_count = 0;

    public SetRatingCommand(Gee.Iterable<DataView> iter, Rating rating) {
        base (iter, Resources.rating_progress(rating), _("Restoring previous rating"),
            Resources.rating_label(rating), "");
        set_direct = true;
        new_rating = rating;

        save_source_states(iter);
    } 
    
    public SetRatingCommand.inc_dec(Gee.Iterable<DataView> iter, bool is_incrementing) {
        base (iter, 
            is_incrementing ? _("Increasing ratings") : _("Decreasing ratings"),
            is_incrementing ? _("Decreasing ratings") : _("Increasing ratings"), 
            is_incrementing ? Resources.INCREASE_RATING_LABEL : Resources.DECREASE_RATING_LABEL, 
            "");
        set_direct = false;
        incrementing = is_incrementing;
        
        save_source_states(iter);
    }
    
    private void save_source_states(Gee.Iterable<DataView> iter) {
        last_rating_map = new Gee.HashMap<DataSource, Rating>();

        foreach (DataView view in iter) {
            DataSource source = view.get_source();
            last_rating_map[source] = ((MediaSource) source).get_rating();
        }
    }
    
    public override void execute() {
        action_count = 0;
        base.execute();
    }
    
    public override void undo() {
        action_count = 0;
        base.undo();
    }
    
    public override void execute_on_source(DataSource source) {
        if (set_direct)
            ((MediaSource) source).set_rating(new_rating);
        else {
            if (incrementing)
                ((MediaSource) source).increase_rating();
            else
                ((MediaSource) source).decrease_rating();
        }
    }
    
    public override void undo_on_source(DataSource source) {
        ((MediaSource) source).set_rating(last_rating_map[source]);
    }
}

public class SetRawDeveloperCommand : MultipleDataSourceCommand {
    private Gee.HashMap<Photo, RawDeveloper> last_developer_map;
    private RawDeveloper new_developer;

    public SetRawDeveloperCommand(Gee.Iterable<DataView> iter, RawDeveloper developer) {
        base (iter, _("Setting RAW developer"), _("Restoring previous RAW developer"),
            developer.get_label(), "");
        new_developer = developer;
        save_source_states(iter);
    }
    
    private void save_source_states(Gee.Iterable<DataView> iter) {
        last_developer_map = new Gee.HashMap<Photo, RawDeveloper>();
        
        foreach (DataView view in iter) {
            Photo? photo = view.get_source() as Photo;
            if (is_raw_photo(photo))
                last_developer_map[photo] = photo.get_raw_developer();
        }
    }
    
    public override void execute() {
        base.execute();
    }
    
    public override void undo() {
        base.undo();
    }
    
    public override void execute_on_source(DataSource source) {
        Photo? photo = source as Photo;
        if (is_raw_photo(photo)) {
            if (new_developer == RawDeveloper.CAMERA && !photo.is_raw_developer_available(RawDeveloper.CAMERA))
                photo.set_raw_developer(RawDeveloper.EMBEDDED);
            else
                photo.set_raw_developer(new_developer);
        }
    }
    
    public override void undo_on_source(DataSource source) {
        Photo? photo = source as Photo;
        if (is_raw_photo(photo))
            photo.set_raw_developer(last_developer_map[photo]);
    }
    
    private bool is_raw_photo(Photo? photo) {
        return photo != null && photo.get_master_file_format() == PhotoFileFormat.RAW;
    }
}

public class AdjustDateTimePhotoCommand : SingleDataSourceCommand {
    private Dateable dateable;
    private int64 time_shift;
    private bool modify_original;

    public AdjustDateTimePhotoCommand(Dateable dateable, int64 time_shift, bool modify_original) {
        base(dateable, Resources.ADJUST_DATE_TIME_LABEL, "");

        this.dateable = dateable;
        this.time_shift = time_shift;
        this.modify_original = modify_original;
    }

    public override void execute() {
        set_time(dateable, dateable.get_exposure_time() + (time_t) time_shift);
    }

    public override void undo() {
        set_time(dateable, dateable.get_exposure_time() - (time_t) time_shift);
    }

    private void set_time(Dateable dateable, time_t exposure_time) {
        if (modify_original && dateable is Photo) {
            try {
                ((Photo)dateable).set_exposure_time_persistent(exposure_time);
            } catch(GLib.Error err) {
                AppWindow.error_message(_("Original photo could not be adjusted."));
            }
        } else {
            dateable.set_exposure_time(exposure_time);
        }
    }
}

public class AdjustDateTimePhotosCommand : MultipleDataSourceCommand {
    private int64 time_shift;
    private bool keep_relativity;
    private bool modify_originals;

    // used when photos are batch changed instead of shifted uniformly
    private time_t? new_time = null;
    private Gee.HashMap<Dateable, time_t?> old_times;
    private Gee.ArrayList<Dateable> error_list;

    public AdjustDateTimePhotosCommand(Gee.Iterable<DataView> iter, int64 time_shift,
        bool keep_relativity, bool modify_originals) {
        base(iter, _("Adjusting Date and Time"), _("Undoing Date and Time Adjustment"),
            Resources.ADJUST_DATE_TIME_LABEL, "");

        this.time_shift = time_shift;
        this.keep_relativity = keep_relativity;
        this.modify_originals = modify_originals;

        // TODO: implement modify originals option

        // this should be replaced by a first function when we migrate to Gee's List
        foreach (DataView view in iter) { 
           if (new_time == null) {
                new_time = ((Dateable) view.get_source()).get_exposure_time() +
                    (time_t) time_shift;
                break;
            }            
        }

        old_times = new Gee.HashMap<Dateable, time_t?>();
    }

    public override void execute() {
        error_list = new Gee.ArrayList<Dateable>();
        base.execute();

        if (error_list.size > 0) {
            multiple_object_error_dialog(error_list, 
                ngettext("One original photo could not be adjusted.",
                "The following original photos could not be adjusted.", error_list.size), 
                _("Time Adjustment Error"));
        }
    }

    public override void undo() {
        error_list = new Gee.ArrayList<Dateable>();
        base.undo();

        if (error_list.size > 0) {
            multiple_object_error_dialog(error_list, 
                ngettext("Time adjustments could not be undone on the following photo file.",
                "Time adjustments could not be undone on the following photo files.", 
                error_list.size), _("Time Adjustment Error"));
        }
    }

    private void set_time(Dateable dateable, time_t exposure_time) {
        // set_exposure_time_persistent wouldn't work on videos,
        // since we can't actually write them from inside shotwell,
        // so check whether we're working on a Photo or a Video
        if (modify_originals && (dateable is Photo)) {
            try {
                ((Photo) dateable).set_exposure_time_persistent(exposure_time);
            } catch(GLib.Error err) {
                error_list.add(dateable);
            }
        } else {
            // modifying originals is disabled, or this is a
            // video
            dateable.set_exposure_time(exposure_time);
        }
    }

    public override void execute_on_source(DataSource source) {
        Dateable dateable = ((Dateable) source);

        if (keep_relativity && dateable.get_exposure_time() != 0) {
            set_time(dateable, dateable.get_exposure_time() + (time_t) time_shift);
        } else {
            old_times.set(dateable, dateable.get_exposure_time());
            set_time(dateable, new_time);
        }
    }

    public override void undo_on_source(DataSource source) {
        Dateable photo = ((Dateable) source);

        if (old_times.has_key(photo)) {
            set_time(photo, old_times.get(photo));
            old_times.unset(photo);
        } else {
            set_time(photo, photo.get_exposure_time() - (time_t) time_shift);
        }
    }
}

public class AddTagsCommand : PageCommand {
    private Gee.HashMap<SourceProxy, Gee.ArrayList<MediaSource>> map =
        new Gee.HashMap<SourceProxy, Gee.ArrayList<MediaSource>>();
    
    public AddTagsCommand(string[] paths, Gee.Collection<MediaSource> sources) {
        base (Resources.add_tags_label(paths), "");
        
        // load/create the tags here rather than in execute() so that we can merely use the proxy
        // to access it ... this is important with the redo() case, where the tags may have been
        // created by another proxy elsewhere
        foreach (string path in paths) {
            Gee.List<string> paths_to_create =
                HierarchicalTagUtilities.enumerate_parent_paths(path);
            paths_to_create.add(path);
            
            foreach (string create_path in paths_to_create) {
                Tag tag = Tag.for_path(create_path);
                SourceProxy tag_proxy = tag.get_proxy();
                
                // for each Tag, only attach sources which are not already attached, otherwise undo()
                // will not be symmetric
                Gee.ArrayList<MediaSource> add_sources = new Gee.ArrayList<MediaSource>();
                foreach (MediaSource source in sources) {
                    if (!tag.contains(source))
                        add_sources.add(source);
                }
                
                if (add_sources.size > 0) {
                    tag_proxy.broken.connect(on_proxy_broken);
                    map.set(tag_proxy, add_sources);
                }
            }
        }
        
        LibraryPhoto.global.item_destroyed.connect(on_source_destroyed);
        Video.global.item_destroyed.connect(on_source_destroyed);
    }
    
    ~AddTagsCommand() {
        foreach (SourceProxy tag_proxy in map.keys)
            tag_proxy.broken.disconnect(on_proxy_broken);
        
        LibraryPhoto.global.item_destroyed.disconnect(on_source_destroyed);
        Video.global.item_destroyed.disconnect(on_source_destroyed);
    }
    
    public override void execute() {
        foreach (SourceProxy tag_proxy in map.keys)
            ((Tag) tag_proxy.get_source()).attach_many(map.get(tag_proxy));
    }
    
    public override void undo() {
        foreach (SourceProxy tag_proxy in map.keys) {
            Tag tag = (Tag) tag_proxy.get_source();

            tag.detach_many(map.get(tag_proxy));
            
            if (tag.get_sources_count() == 0)
                Tag.global.destroy_marked(Tag.global.mark(tag), true);
        }
    }
    
    private void on_source_destroyed(DataSource source) {
        foreach (Gee.ArrayList<MediaSource> sources in map.values) {
            if (sources.contains((MediaSource) source)) {
                get_command_manager().reset();
                
                return;
            }
        }
    }
    
    private void on_proxy_broken() {
        get_command_manager().reset();
    }
}

public class RenameTagCommand : SimpleProxyableCommand {
    private string old_name;
    private string new_name;
    
    // NOTE: new_name should be a name, not a path
    public RenameTagCommand(Tag tag, string new_name) {
        base (tag, Resources.rename_tag_label(tag.get_user_visible_name(), new_name),
            tag.get_name());
        
        old_name = tag.get_user_visible_name();
        this.new_name = new_name;
    }
    
    protected override void execute_on_source(DataSource source) {
        if (!((Tag) source).rename(new_name))
            AppWindow.error_message(Resources.rename_tag_exists_message(new_name));
    }

    protected override void undo_on_source(DataSource source) {
        if (!((Tag) source).rename(old_name))
            AppWindow.error_message(Resources.rename_tag_exists_message(old_name));
    }
}

public class DeleteTagCommand : SimpleProxyableCommand {
    Gee.List<SourceProxy>? recursive_victim_proxies = null;

    public DeleteTagCommand(Tag tag) {
        base (tag, Resources.delete_tag_label(tag.get_user_visible_name()), tag.get_name());
    }
    
    protected override void execute_on_source(DataSource source) {
        Tag tag = (Tag) source;
        
        Gee.List<Tag>? recursive_victims = tag.get_hierarchical_children();
        
        // if this tag has no children just destroy it and do a short-circuit return
        if (recursive_victims.size == 0) {
            Tag.global.destroy_marked(Tag.global.mark(source), false);
            return;
        }
        
        // okay, this tag has children, so they need to be proxied and deleted as well
        recursive_victim_proxies = new Gee.ArrayList<SourceProxy>();
        
        foreach (Tag victim in recursive_victims) {
            recursive_victim_proxies.add(victim.get_proxy());

            Tag.global.destroy_marked(Tag.global.mark(victim), false);
        }
        
        Tag.global.destroy_marked(Tag.global.mark(source), false);
    }
    
    protected override void undo_on_source(DataSource source) {
        // merely instantiating the Tag will rehydrate it ... should always work, because the 
        // undo stack is cleared if the proxy ever breaks
        assert(source is Tag);
               
        if (recursive_victim_proxies != null) {
            for (int i = recursive_victim_proxies.size - 1; i >= 0; i--) {
                DataSource victim_source = recursive_victim_proxies.get(i).get_source();
                assert(victim_source is Tag);
            }
        }
    }
}

public class NewChildTagCommand : SimpleProxyableCommand {
    Tag? created_child = null;
    
    public NewChildTagCommand(Tag tag) {
        base (tag, _("Create Tag"), tag.get_name());
    }
    
    protected override void execute_on_source(DataSource source) {
        Tag tag = (Tag) source;
        created_child = tag.create_new_child();
    }
    
    protected override void undo_on_source(DataSource source) {
        Tag.global.destroy_marked(Tag.global.mark(created_child), true);
    }
    
    public Tag get_created_child() {
        assert(created_child != null);
        
        return created_child;
    }
}

public class NewRootTagCommand : PageCommand {
    Tag? created = null;
    
    public NewRootTagCommand() {
        base (_("Create Tag"), "");
    }
    
    protected override void execute() {
        created = Tag.create_new_root();
        SourceProxy tag_proxy = created.get_proxy();
        tag_proxy.broken.connect(on_proxy_broken);
    }
    
    protected override void undo() {
        Tag.global.destroy_marked(Tag.global.mark(created), true);
    }
    
    public Tag get_created_tag() {
        assert(created != null);
        
        return created;
    }
    
    private void on_proxy_broken() {
        get_command_manager().reset();
    }
}

public class ReparentTagCommand : PageCommand {
    string basename;
    string from_path;
    string to_path;
    
    public ReparentTagCommand(Tag tag, string new_parent_path) {
        base (_("Move Tag \"%s\"").printf(tag.get_user_visible_name()), "");

        this.basename = tag.get_user_visible_name();
        this.from_path = tag.get_path();

        bool has_children = (tag.get_hierarchical_children().size > 0);

        if (new_parent_path == Tag.PATH_SEPARATOR_STRING)
            this.to_path = (has_children) ? (Tag.PATH_SEPARATOR_STRING + basename) : basename;
        else if (new_parent_path.has_prefix(Tag.PATH_SEPARATOR_STRING))
            this.to_path = new_parent_path + Tag.PATH_SEPARATOR_STRING + basename;
        else
            this.to_path = Tag.PATH_SEPARATOR_STRING + new_parent_path + Tag.PATH_SEPARATOR_STRING +
                basename;
    }
    
    private void do_move(string from, string to) {
        // make sure a tag corresponding to the from path exists -- this should always be true,
        // given the way the constructor for this class works, but it's a sanity check
        Tag? from_tag = null;
        if (!Tag.exists(from))
            error("do_move: can't move from tag with path '%s': tag doesn't exist.", from);
        from_tag = Tag.for_path(from);
        
        // if the from tag has any children they need to be moved recursively with the from tag,
        // so enumerate them
        Gee.List<Tag> from_children = new Gee.ArrayList<Tag>();
        from_children.add_all(from_tag.get_hierarchical_children());
        
        // make a list of all the sources in the from tag
        Gee.Set<MediaSource> from_sources = new Gee.HashSet<MediaSource>();
        from_sources.add_all(from_tag.get_sources());
        
        // keep track of which sources belong to which children since we need to recreate the
        // child structure exactly
        Gee.Map<string, Gee.Set<MediaSource>> child_structure =
            new Gee.TreeMap<string, Gee.Set<MediaSource>>();
        
        // loop through sources and detach them
        foreach (MediaSource source in from_sources) {
            // detach the current source from all child tags of the from tag
            foreach (Tag child in from_children) {
                string child_subpath = child.get_path().replace(from + Tag.PATH_SEPARATOR_STRING,
                    "");
                if (!child_structure.has_key(child_subpath))
                    child_structure.set(child_subpath, new Gee.HashSet<MediaSource>());
                
                if (child.contains(source)) {
                    child_structure.get(child_subpath).add(source);
                }
            }
            
            // detach the current source from the from tag itself
            from_tag.detach(source);
            
            // detach the current source from all of the parent tags of the from tag
            Tag? current_parent = from_tag.get_hierarchical_parent();
            while (current_parent != null) {
                current_parent.detach(source);
                
                current_parent = current_parent.get_hierarchical_parent();
            }
        }
        
        // find our new parent tag (if one exists) and promote it
        Tag? new_parent = null;
        if (to.has_prefix(Tag.PATH_SEPARATOR_STRING)) {
            Gee.List<string> parent_paths = HierarchicalTagUtilities.enumerate_parent_paths(to);
            if (parent_paths.size > 0) {
                string immediate_parent_path = parent_paths.get(parent_paths.size - 1);
                if (Tag.exists(immediate_parent_path))
                    new_parent = Tag.for_path(immediate_parent_path);
                else if (Tag.exists(immediate_parent_path.substring(1)))
                    new_parent = Tag.for_path(immediate_parent_path.substring(1));
                else
                    assert_not_reached();
            }
        }    
        if (new_parent != null)
            new_parent.promote();

        // get (or create) a tag for the destination path and attach all of the sources to it;
        // also attach all of the sources to the parents of the destination tag, if any
        Tag to_tag = Tag.for_path(to);
        foreach (MediaSource current_from_source in from_sources) {
            to_tag.attach(current_from_source);
            
            Tag? parent = to_tag.get_hierarchical_parent();
            while (parent != null) {
                parent.attach(current_from_source);
            
                parent = parent.get_hierarchical_parent();
            }
        }

        // create our child paths, if any, and attach their sources
        foreach (string curr_child_subpath in child_structure.keys) {
            string curr_child_path = to_tag.get_path() + Tag.PATH_SEPARATOR_STRING +
                curr_child_subpath;
            Tag curr_child_tag = Tag.for_path(curr_child_path);
            foreach (MediaSource src_in_child in child_structure.get(curr_child_subpath)) {
                curr_child_tag.attach(src_in_child);
            }
        }
        
        // cleanup our old children
        Tag.global.destroy_marked(Tag.global.mark_many(from_children), true);
        
        // cleanup our old tag -- keep in mind that when our children were removed, we
        // may have been flattened
        if (Tag.exists(from)) {
            Tag.global.destroy_marked(Tag.global.mark(Tag.for_path(from)), true);
            
            return;
        }
        if (HierarchicalTagUtilities.enumerate_path_components(from).size == 1) {
            string from_flat = HierarchicalTagUtilities.hierarchical_to_flat(from);
            if (Tag.exists(from_flat))
                Tag.global.destroy_marked(Tag.global.mark(Tag.for_path(from_flat)), true);
                
            return;
        }
    }
    
    public override void execute() {
        do_move(from_path, to_path);
    }
    
    public override void undo() {
        do_move(to_path, from_path);
    }
}

public class ModifyTagsCommand : SingleDataSourceCommand {
    private MediaSource media;
    private Gee.ArrayList<SourceProxy> to_add = new Gee.ArrayList<SourceProxy>();
    private Gee.ArrayList<SourceProxy> to_remove = new Gee.ArrayList<SourceProxy>();
    
    public ModifyTagsCommand(MediaSource media, Gee.Collection<Tag> new_tag_list) {
        base (media, Resources.MODIFY_TAGS_LABEL, "");
        
        this.media = media;
        
        // Prepare to remove all existing tags, if any, from the current media source.
        Gee.List<Tag>? original_tags = Tag.global.fetch_for_source(media);
        if (original_tags != null) {
            foreach (Tag tag in original_tags) {
                SourceProxy proxy = tag.get_proxy();
                to_remove.add(proxy);
                proxy.broken.connect(on_proxy_broken);
            }
        }
        
        // Prepare to add all new tags; remember, if a tag is added, its parent must be
        // added as well. So enumerate all paths to add and then get the tags for them.
        Gee.SortedSet<string> new_paths = new Gee.TreeSet<string>();
        foreach (Tag new_tag in new_tag_list) {
            string new_tag_path = new_tag.get_path();

            new_paths.add(new_tag_path);
            new_paths.add_all(HierarchicalTagUtilities.enumerate_parent_paths(new_tag_path));
        }
        
        foreach (string path in new_paths) {
            assert(Tag.exists(path));

            SourceProxy proxy = Tag.for_path(path).get_proxy();
            to_add.add(proxy);
            proxy.broken.connect(on_proxy_broken);
        }
    }
    
    ~ModifyTagsCommand() {
        foreach (SourceProxy proxy in to_add)
            proxy.broken.disconnect(on_proxy_broken);
        
        foreach (SourceProxy proxy in to_remove)
            proxy.broken.disconnect(on_proxy_broken);
    }
    
    public override void execute() {
        foreach (SourceProxy proxy in to_remove)
            ((Tag) proxy.get_source()).detach(media);
            
        foreach (SourceProxy proxy in to_add)
            ((Tag) proxy.get_source()).attach(media);
    }
    
    public override void undo() {
        foreach (SourceProxy proxy in to_add)
            ((Tag) proxy.get_source()).detach(media);
        
        foreach (SourceProxy proxy in to_remove)
            ((Tag) proxy.get_source()).attach(media);
    }
    
    private void on_proxy_broken() {
        get_command_manager().reset();
    }
}

public class TagUntagPhotosCommand : SimpleProxyableCommand {
    private Gee.Collection<MediaSource> sources;
    private bool attach;
    
    public TagUntagPhotosCommand(Tag tag, Gee.Collection<MediaSource> sources, int count, bool attach) {
        base (tag,
            attach ? Resources.tag_photos_label(tag.get_user_visible_name(), count) 
                : Resources.untag_photos_label(tag.get_user_visible_name(), count),
            tag.get_name());
        
        this.sources = sources;
        this.attach = attach;
        
        LibraryPhoto.global.item_destroyed.connect(on_source_destroyed);
        Video.global.item_destroyed.connect(on_source_destroyed);
    }
    
    ~TagPhotosCommand() {
        LibraryPhoto.global.item_destroyed.disconnect(on_source_destroyed);
        Video.global.item_destroyed.disconnect(on_source_destroyed);
    }
    
    public override void execute_on_source(DataSource source) {
        if (attach)
            ((Tag) source).attach_many(sources);
        else
            ((Tag) source).detach_many(sources);
    }
    
    public override void undo_on_source(DataSource source) {
        if (attach)
            ((Tag) source).detach_many(sources);
        else
            ((Tag) source).attach_many(sources);
    }
    
    private void on_source_destroyed(DataSource source) {
        if (sources.contains((MediaSource) source))
            get_command_manager().reset();
    }
}

public class RenameSavedSearchCommand : SingleDataSourceCommand {
    private SavedSearch search;
    private string old_name;
    private string new_name;
    
    public RenameSavedSearchCommand(SavedSearch search, string new_name) {
        base (search, Resources.rename_search_label(search.get_name(), new_name), search.get_name());
            
        this.search = search;
        old_name = search.get_name();
        this.new_name = new_name;
    }
    
    public override void execute() {
        if (!search.rename(new_name))
            AppWindow.error_message(Resources.rename_search_exists_message(new_name));
    }

    public override void undo() {
        if (!search.rename(old_name))
            AppWindow.error_message(Resources.rename_search_exists_message(old_name));
    }
}

public class DeleteSavedSearchCommand : SingleDataSourceCommand {
    private SavedSearch search;
    
    public DeleteSavedSearchCommand(SavedSearch search) {
        base (search, Resources.delete_search_label(search.get_name()), search.get_name());
            
        this.search = search;
    }
    
    public override void execute() {
        SavedSearchTable.get_instance().remove(search);
    }

    public override void undo() {
        search.reconstitute();
    }
}

public class TrashUntrashPhotosCommand : PageCommand {
    private Gee.Collection<MediaSource> sources;
    private bool to_trash;
    
    public TrashUntrashPhotosCommand(Gee.Collection<MediaSource> sources, bool to_trash) {
        base (
            to_trash ? _("Move Photos to Trash") : _("Restore Photos from Trash"),
            to_trash ? _("Move the photos to the Shotwell trash") : _("Restore the photos back to the Shotwell library"));
        
        this.sources = sources;
        this.to_trash = to_trash;
        
        LibraryPhoto.global.item_destroyed.connect(on_photo_destroyed);
        Video.global.item_destroyed.connect(on_photo_destroyed);
    }
    
    ~TrashUntrashPhotosCommand() {
        LibraryPhoto.global.item_destroyed.disconnect(on_photo_destroyed);
        Video.global.item_destroyed.disconnect(on_photo_destroyed);
    }
    
    private ProgressDialog? get_progress_dialog(bool to_trash) {
        if (sources.size <= 5)
            return null;
        
        ProgressDialog dialog = new ProgressDialog(AppWindow.get_instance(),
            to_trash ? _("Moving Photos to Trash") : _("Restoring Photos From Trash"));
        dialog.update_display_every((sources.size / 5).clamp(2, 10));
        
        return dialog;
    }
    
    public override void execute() {
        ProgressDialog? dialog = get_progress_dialog(to_trash);
        
        ProgressMonitor monitor = null;
        if (dialog != null)
            monitor = dialog.monitor;
        
        if (to_trash)
            trash(monitor);
        else
            untrash(monitor);
        
        if (dialog != null)
            dialog.close();
    }
    
    public override void undo() {
        ProgressDialog? dialog = get_progress_dialog(!to_trash);
        
        ProgressMonitor monitor = null;
        if (dialog != null)
            monitor = dialog.monitor;
        
        if (to_trash)
            untrash(monitor);
        else
            trash(monitor);
        
        if (dialog != null)
            dialog.close();
    }
    
    private void trash(ProgressMonitor? monitor) {
        int ctr = 0;
        int count = sources.size;
        
        LibraryPhoto.global.transaction_controller.begin();
        Video.global.transaction_controller.begin();
        
        foreach (MediaSource source in sources) {
            source.trash();
            if (monitor != null)
                monitor(++ctr, count);
        }
        
        LibraryPhoto.global.transaction_controller.commit();
        Video.global.transaction_controller.commit();
    }
    
    private void untrash(ProgressMonitor? monitor) {
        int ctr = 0;
        int count = sources.size;
        
        LibraryPhoto.global.transaction_controller.begin();
        Video.global.transaction_controller.begin();
        
        foreach (MediaSource source in sources) {
            source.untrash();
            if (monitor != null)
                monitor(++ctr, count);
        }
        
        LibraryPhoto.global.transaction_controller.commit();
        Video.global.transaction_controller.commit();
    }
    
    private void on_photo_destroyed(DataSource source) {
        // in this case, don't need to reset the command manager, simply remove the photo from the
        // internal list and allow the others to be moved to and from the trash
        sources.remove((MediaSource) source);
        
        // however, if all photos missing, then remove this from the command stack, and there's
        // only one way to do that
        if (sources.size == 0)
            get_command_manager().reset();
    }
}

public class FlagUnflagCommand : MultipleDataSourceAtOnceCommand {
    private bool flag;
    
    public FlagUnflagCommand(Gee.Collection<MediaSource> sources, bool flag) {
        base (sources,
            flag ? _("Flag") : _("Unflag"),
            flag ? _("Flag selected photos") : _("Unflag selected photos"));
        
        this.flag = flag;
    }
    
    public override void execute_on_all(Gee.Collection<DataSource> sources) {
        foreach (DataSource source in sources)
            flag_unflag(source, flag);
    }
    
    public override void undo_on_all(Gee.Collection<DataSource> sources) {
        foreach (DataSource source in sources)
            flag_unflag(source, !flag);
    }
    
    private void flag_unflag(DataSource source, bool flag) {
        Flaggable? flaggable = source as Flaggable;
        if (flaggable != null) {
            if (flag)
                flaggable.mark_flagged();
            else
                flaggable.mark_unflagged();
        }
    }
}

public class RemoveFacesFromPhotosCommand : SimpleProxyableCommand {
    private Gee.Map<MediaSource, string> map_source_geometry = new Gee.HashMap<MediaSource, string>();
    
    public RemoveFacesFromPhotosCommand(Face face, Gee.Collection<MediaSource> sources, int count) {
        base (face,
            Resources.remove_face_from_photos_label(face.get_name(), count),
            face.get_name());
        
        foreach (MediaSource source in sources) {
            FaceLocation? face_location =
                FaceLocation.get_face_location(face.get_face_id(), ((Photo) source).get_photo_id());
            assert(face_location != null);
            
            this.map_source_geometry.set(source, face_location.get_serialized_geometry());
        }
        
        LibraryPhoto.global.item_destroyed.connect(on_source_destroyed);
        Video.global.item_destroyed.connect(on_source_destroyed);
    }
    
    ~RemoveFacesFromPhotosCommand() {
        LibraryPhoto.global.item_destroyed.disconnect(on_source_destroyed);
        Video.global.item_destroyed.disconnect(on_source_destroyed);
    }
    
    public override void execute_on_source(DataSource source) {
        ((Face) source).detach_many(map_source_geometry.keys);
    }
    
    public override void undo_on_source(DataSource source) {
        Face face = (Face) source;
        
        face.attach_many(map_source_geometry.keys);
        foreach (Gee.Map.Entry<MediaSource, string> entry in map_source_geometry.entries)
            FaceLocation.create(face.get_face_id(), ((Photo) entry.key).get_photo_id(), entry.value);
    }
    
    private void on_source_destroyed(DataSource source) {
        if (map_source_geometry.keys.contains((MediaSource) source))
            get_command_manager().reset();
    }
}

public class RenameFaceCommand : SimpleProxyableCommand {
    private string old_name;
    private string new_name;
    
    public RenameFaceCommand(Face face, string new_name) {
        base (face, Resources.rename_face_label(face.get_name(), new_name), face.get_name());
        
        old_name = face.get_name();
        this.new_name = new_name;
    }
    
    protected override void execute_on_source(DataSource source) {
        if (!((Face) source).rename(new_name))
            AppWindow.error_message(Resources.rename_face_exists_message(new_name));
    }

    protected override void undo_on_source(DataSource source) {
        if (!((Face) source).rename(old_name))
            AppWindow.error_message(Resources.rename_face_exists_message(old_name));
    }
}

public class DeleteFaceCommand : SimpleProxyableCommand {
    private Gee.Map<PhotoID?, string> photo_geometry_map =
        new Gee.HashMap<PhotoID?, string>(FaceLocation.photo_id_hash, FaceLocation.photo_ids_equal);
    
    public DeleteFaceCommand(Face face) {
        base (face, Resources.delete_face_label(face.get_name()), face.get_name());
        
        // we can't use the Gee.Map returned by FaceLocation.get_locations_by_face
        // because it will be modified in execute_on_source
        Gee.Map<PhotoID?, FaceLocation>? temp = FaceLocation.get_locations_by_face(face);
        assert(temp != null);
        foreach (Gee.Map.Entry<PhotoID?, FaceLocation> entry in temp.entries)
            photo_geometry_map.set(entry.key, entry.value.get_serialized_geometry());
    }
    
    protected override void execute_on_source(DataSource source) {
        FaceID face_id = ((Face) source).get_face_id();
        foreach (PhotoID photo_id in photo_geometry_map.keys)
            FaceLocation.destroy(face_id, photo_id);
        
        Face.global.destroy_marked(Face.global.mark(source), false);
    }
    
    protected override void undo_on_source(DataSource source) {
        // merely instantiating the Face will rehydrate it ... should always work, because the 
        // undo stack is cleared if the proxy ever breaks
        assert(source is Face);
        
        foreach (Gee.Map.Entry<PhotoID?, string> entry in photo_geometry_map.entries) {
            Photo? photo = LibraryPhoto.global.fetch(entry.key);
            
            if (photo != null) {
                Face face = (Face) source;
                
                face.attach(photo);
                FaceLocation.create(face.get_face_id(), entry.key, entry.value);
            }
        }
    }
}

public class ModifyFacesCommand : SingleDataSourceCommand {
    private MediaSource media;
    private Gee.ArrayList<SourceProxy> to_add = new Gee.ArrayList<SourceProxy>();
    private Gee.ArrayList<SourceProxy> to_remove = new Gee.ArrayList<SourceProxy>();
    private Gee.Map<SourceProxy, string> to_update = new Gee.HashMap<SourceProxy, string>();
    private Gee.Map<SourceProxy, string> geometries = new Gee.HashMap<SourceProxy, string>();
    
    public ModifyFacesCommand(MediaSource media, Gee.Map<Face, string> new_face_list) {
        base (media, Resources.MODIFY_FACES_LABEL, "");
        
        this.media = media;
        
        // Remove any face that's in the original list but not the new one
        Gee.Collection<Face>? original_faces = Face.global.fetch_for_source(media);
        if (original_faces != null) {
            foreach (Face face in original_faces) {
                if (!new_face_list.keys.contains(face)) {
                    SourceProxy proxy = face.get_proxy();
                    
                    to_remove.add(proxy);
                    proxy.broken.connect(on_proxy_broken);
                    
                    FaceLocation? face_location =
                        FaceLocation.get_face_location(face.get_face_id(), ((Photo) media).get_photo_id());
                    assert(face_location != null);
                    
                    geometries.set(proxy, face_location.get_serialized_geometry());
                }
            }
        }
        
        // Add any face that's in the new list but not the original
        foreach (Gee.Map.Entry<Face, string> entry in new_face_list.entries) {
            if (original_faces == null || !original_faces.contains(entry.key)) {
                SourceProxy proxy = entry.key.get_proxy();
                
                to_add.add(proxy);
                proxy.broken.connect(on_proxy_broken);
                
                geometries.set(proxy, entry.value);
            } else {
                // If it is already in the original list we need to check if it's
                // geometry has changed.
                FaceLocation? face_location =
                    FaceLocation.get_face_location(entry.key.get_face_id(), ((Photo) media).get_photo_id());
                assert(face_location != null);
                
                string old_geometry = face_location.get_serialized_geometry();
                if (old_geometry != entry.value) {
                    SourceProxy proxy = entry.key.get_proxy();
                    
                    to_update.set(proxy, entry.value);
                    proxy.broken.connect(on_proxy_broken);
                    
                    geometries.set(proxy, old_geometry);
                }
            }
        }
    }
    
    ~ModifyFacesCommand() {
        foreach (SourceProxy proxy in to_add)
            proxy.broken.disconnect(on_proxy_broken);
        
        foreach (SourceProxy proxy in to_remove)
            proxy.broken.disconnect(on_proxy_broken);
        
        foreach (SourceProxy proxy in to_update.keys)
            proxy.broken.disconnect(on_proxy_broken);
    }
    
    public override void execute() {
        foreach (SourceProxy proxy in to_add) {
            Face face = (Face) proxy.get_source();
            face.attach(media);
            FaceLocation.create(face.get_face_id(), ((Photo) media).get_photo_id(), geometries.get(proxy));
        }
        
        foreach (SourceProxy proxy in to_remove)
            ((Face) proxy.get_source()).detach(media);
        
        foreach (Gee.Map.Entry<SourceProxy, string> entry in to_update.entries) {
            Face face = (Face) entry.key.get_source();
            FaceLocation.create(face.get_face_id(), ((Photo) media).get_photo_id(), entry.value);
        }
    }
    
    public override void undo() {
        foreach (SourceProxy proxy in to_add)
            ((Face) proxy.get_source()).detach(media);
        
        foreach (SourceProxy proxy in to_remove) {
            Face face = (Face) proxy.get_source();
            face.attach(media);
            FaceLocation.create(face.get_face_id(), ((Photo) media).get_photo_id(), geometries.get(proxy));
        }
        
        foreach (SourceProxy proxy in to_update.keys) {
            Face face = (Face) proxy.get_source();
            FaceLocation.create(face.get_face_id(), ((Photo) media).get_photo_id(), geometries.get(proxy));
        }
    }
    
    private void on_proxy_broken() {
        get_command_manager().reset();
    }
}
