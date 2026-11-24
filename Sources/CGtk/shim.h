// Тонкая прослойка между Swift и GTK4/libadwaita (Linux-версия iPod Converter).
// Макросы GTK (GTK_BOX(), g_signal_connect…) в Swift недоступны — здесь они спрятаны в функции,
// которые принимают и возвращают просто GtkWidget*.
#pragma once
#include <adwaita.h>
#include <string.h>

typedef void (*cg_cb)(void *data);
typedef void (*cg_paths_cb)(const char *paths, void *data);

// --- Приложение и цикл событий ---
static inline GtkApplication *cg_app_new(const char *id) {
    return GTK_APPLICATION(adw_application_new(id, G_APPLICATION_DEFAULT_FLAGS));
}
typedef struct { cg_cb fn; void *data; } cg_closure;
static void cg__run(gpointer self, gpointer user) { cg_closure *c = user; c->fn(c->data); }
static void cg__run3(gpointer self, gpointer a, gpointer user) { cg_closure *c = user; c->fn(c->data); }
static gboolean cg__run_bool(gpointer self, gpointer user) { cg_closure *c = user; c->fn(c->data); return FALSE; }
static inline cg_closure *cg__mk(cg_cb fn, void *data) {
    cg_closure *c = g_new0(cg_closure, 1); c->fn = fn; c->data = data; return c;
}
static void cg__free(gpointer c, GClosure *cl) { g_free(c); }
/// Сигнал без аргументов (clicked, activate, toggled…): fn(data).
static inline void cg_on(gpointer obj, const char *signal, cg_cb fn, void *data) {
    g_signal_connect_data(obj, signal, G_CALLBACK(cg__run), cg__mk(fn, data), cg__free, 0);
}
/// Сигнал с одним доп. аргументом (notify::selected).
static inline void cg_on3(gpointer obj, const char *signal, cg_cb fn, void *data) {
    g_signal_connect_data(obj, signal, G_CALLBACK(cg__run3), cg__mk(fn, data), cg__free, 0);
}
/// close-request: вызвать fn и разрешить закрытие.
static inline void cg_on_close(GtkWidget *win, cg_cb fn, void *data) {
    g_signal_connect_data(win, "close-request", G_CALLBACK(cg__run_bool), cg__mk(fn, data), cg__free, 0);
}
static inline void cg_app_start(GtkApplication *a) {
    g_application_register(G_APPLICATION(a), NULL, NULL);
    g_application_activate(G_APPLICATION(a));
}
static inline gboolean cg_iterate(void) { return g_main_context_iteration(NULL, FALSE); }

// --- Окно и раскладка ---
static inline GtkWidget *cg_window(GtkApplication *app, const char *title, int w, int h) {
    GtkWidget *win = adw_application_window_new(app);
    gtk_window_set_title(GTK_WINDOW(win), title);
    gtk_window_set_default_size(GTK_WINDOW(win), w, h);
    gtk_window_set_icon_name(GTK_WINDOW(win), "io.github.ipodconverter.linux");
    return win;
}
static inline void cg_window_set_content(GtkWidget *win, GtkWidget *child) {
    adw_application_window_set_content(ADW_APPLICATION_WINDOW(win), child);
}
static inline void cg_present(GtkWidget *win) { gtk_window_present(GTK_WINDOW(win)); }
static inline GtkWidget *cg_toolbar_view(void) { return adw_toolbar_view_new(); }
static inline void cg_toolbar_top(GtkWidget *tv, GtkWidget *bar) { adw_toolbar_view_add_top_bar(ADW_TOOLBAR_VIEW(tv), bar); }
static inline void cg_toolbar_bottom(GtkWidget *tv, GtkWidget *bar) { adw_toolbar_view_add_bottom_bar(ADW_TOOLBAR_VIEW(tv), bar); }
static inline void cg_toolbar_content(GtkWidget *tv, GtkWidget *c) { adw_toolbar_view_set_content(ADW_TOOLBAR_VIEW(tv), c); }
static inline GtkWidget *cg_header(void) { return adw_header_bar_new(); }
static inline void cg_header_start(GtkWidget *h, GtkWidget *w) { adw_header_bar_pack_start(ADW_HEADER_BAR(h), w); }
static inline void cg_header_end(GtkWidget *h, GtkWidget *w) { adw_header_bar_pack_end(ADW_HEADER_BAR(h), w); }
static inline GtkWidget *cg_box(gboolean vertical, int spacing) {
    return gtk_box_new(vertical ? GTK_ORIENTATION_VERTICAL : GTK_ORIENTATION_HORIZONTAL, spacing);
}
static inline void cg_append(GtkWidget *box, GtkWidget *child) { gtk_box_append(GTK_BOX(box), child); }
static inline void cg_margins(GtkWidget *w, int t, int r, int b, int l) {
    gtk_widget_set_margin_top(w, t); gtk_widget_set_margin_end(w, r);
    gtk_widget_set_margin_bottom(w, b); gtk_widget_set_margin_start(w, l);
}
static inline void cg_hexpand(GtkWidget *w, gboolean e) { gtk_widget_set_hexpand(w, e); }
static inline void cg_vexpand(GtkWidget *w, gboolean e) { gtk_widget_set_vexpand(w, e); }
static inline void cg_halign(GtkWidget *w, int a) { gtk_widget_set_halign(w, (GtkAlign)a); }
static inline void cg_valign(GtkWidget *w, int a) { gtk_widget_set_valign(w, (GtkAlign)a); }
static inline void cg_sensitive(GtkWidget *w, gboolean s) { gtk_widget_set_sensitive(w, s); }
static inline void cg_visible(GtkWidget *w, gboolean v) { gtk_widget_set_visible(w, v); }
static inline void cg_tooltip(GtkWidget *w, const char *t) { gtk_widget_set_tooltip_text(w, t); }
static inline void cg_css_class(GtkWidget *w, const char *c) { gtk_widget_add_css_class(w, c); }
static inline void cg_css_remove(GtkWidget *w, const char *c) { gtk_widget_remove_css_class(w, c); }
static inline void cg_size(GtkWidget *w, int width, int height) { gtk_widget_set_size_request(w, width, height); }
static inline GtkWidget *cg_scrolled(GtkWidget *child) {
    GtkWidget *s = gtk_scrolled_window_new();
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(s), child);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(s), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_widget_set_vexpand(s, TRUE);
    return s;
}
static inline GtkWidget *cg_clamp(GtkWidget *child, int max) {
    GtkWidget *c = adw_clamp_new();
    adw_clamp_set_maximum_size(ADW_CLAMP(c), max);
    adw_clamp_set_child(ADW_CLAMP(c), child);
    return c;
}

// --- Виджеты ---
static inline GtkWidget *cg_label(const char *text) {
    GtkWidget *l = gtk_label_new(text);
    gtk_label_set_xalign(GTK_LABEL(l), 0);
    return l;
}
static inline void cg_label_set(GtkWidget *l, const char *text) { gtk_label_set_text(GTK_LABEL(l), text); }
static inline void cg_label_ellipsize(GtkWidget *l) { gtk_label_set_ellipsize(GTK_LABEL(l), PANGO_ELLIPSIZE_MIDDLE); }
static inline void cg_label_wrap(GtkWidget *l) { gtk_label_set_wrap(GTK_LABEL(l), TRUE); }
static inline GtkWidget *cg_button(const char *label) { return gtk_button_new_with_label(label); }
static inline GtkWidget *cg_icon_button(const char *icon) { return gtk_button_new_from_icon_name(icon); }
static inline void cg_button_set_label(GtkWidget *b, const char *t) { gtk_button_set_label(GTK_BUTTON(b), t); }
static inline GtkWidget *cg_check(void) { return gtk_check_button_new(); }
static inline gboolean cg_check_get(GtkWidget *c) { return gtk_check_button_get_active(GTK_CHECK_BUTTON(c)); }
static inline void cg_check_set(GtkWidget *c, gboolean a) { gtk_check_button_set_active(GTK_CHECK_BUTTON(c), a); }
static inline GtkWidget *cg_toggle(const char *label) { return gtk_toggle_button_new_with_label(label); }
static inline void cg_toggle_group(GtkWidget *t, GtkWidget *group) { gtk_toggle_button_set_group(GTK_TOGGLE_BUTTON(t), GTK_TOGGLE_BUTTON(group)); }
static inline gboolean cg_toggle_get(GtkWidget *t) { return gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(t)); }
static inline void cg_toggle_set(GtkWidget *t, gboolean a) { gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(t), a); }
static inline GtkWidget *cg_progress(void) { return gtk_progress_bar_new(); }
static inline void cg_progress_set(GtkWidget *p, double f) { gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(p), f); }
static inline GtkWidget *cg_image_file(const char *path, int size) {
    GtkWidget *p = gtk_picture_new_for_filename(path);
    gtk_picture_set_content_fit(GTK_PICTURE(p), GTK_CONTENT_FIT_COVER);
    gtk_widget_set_size_request(p, size * 16 / 9, size);
    return p;
}
static inline GtkWidget *cg_icon(const char *name, int size) {
    GtkWidget *i = gtk_image_new_from_icon_name(name);
    gtk_image_set_pixel_size(GTK_IMAGE(i), size);
    return i;
}
static inline GtkWidget *cg_status_page(const char *icon, const char *title, const char *desc) {
    GtkWidget *s = adw_status_page_new();
    adw_status_page_set_icon_name(ADW_STATUS_PAGE(s), icon);
    adw_status_page_set_title(ADW_STATUS_PAGE(s), title);
    adw_status_page_set_description(ADW_STATUS_PAGE(s), desc);
    gtk_widget_set_vexpand(s, TRUE);
    return s;
}

// --- Список ---
static inline GtkWidget *cg_listbox(void) {
    GtkWidget *l = gtk_list_box_new();
    gtk_list_box_set_selection_mode(GTK_LIST_BOX(l), GTK_SELECTION_NONE);
    gtk_widget_add_css_class(l, "boxed-list");
    return l;
}
static inline void cg_listbox_append(GtkWidget *l, GtkWidget *row) { gtk_list_box_append(GTK_LIST_BOX(l), row); }
static inline void cg_listbox_clear(GtkWidget *l) { gtk_list_box_remove_all(GTK_LIST_BOX(l)); }

// --- Выпадающий список ---
static inline GtkWidget *cg_dropdown(const char *const *items) { return gtk_drop_down_new_from_strings(items); }
static inline guint cg_dropdown_get(GtkWidget *d) { return gtk_drop_down_get_selected(GTK_DROP_DOWN(d)); }
static inline void cg_dropdown_set(GtkWidget *d, guint i) { gtk_drop_down_set_selected(GTK_DROP_DOWN(d), i); }
static inline void cg_dropdown_items(GtkWidget *d, const char *const *items) {
    GtkStringList *sl = gtk_string_list_new(items);
    gtk_drop_down_set_model(GTK_DROP_DOWN(d), G_LIST_MODEL(sl));
    g_object_unref(sl);
}

// --- Выбор файлов и папок (асинхронно), результат — пути через перевод строки ---
typedef struct { cg_paths_cb fn; void *data; int folder; } cg_dlg;
static void cg__collect(GListModel *files, cg_dlg *d) {
    GString *s = g_string_new(NULL);
    if (files) {
        guint n = g_list_model_get_n_items(files);
        for (guint i = 0; i < n; i++) {
            GFile *f = G_FILE(g_list_model_get_item(files, i));
            char *p = g_file_get_path(f);
            if (p) { if (s->len) g_string_append_c(s, '\n'); g_string_append(s, p); g_free(p); }
            g_object_unref(f);
        }
        g_object_unref(files);
    }
    d->fn(s->str, d->data);
    g_string_free(s, TRUE);
    g_free(d);
}
static void cg__open_done(GObject *src, GAsyncResult *res, gpointer user) {
    cg_dlg *d = user;
    GListModel *files = d->folder
        ? gtk_file_dialog_select_multiple_folders_finish(GTK_FILE_DIALOG(src), res, NULL)
        : gtk_file_dialog_open_multiple_finish(GTK_FILE_DIALOG(src), res, NULL);
    cg__collect(files, d);
}
static inline void cg_choose(GtkWidget *parent, gboolean folders, const char *title, cg_paths_cb fn, void *data) {
    GtkFileDialog *dlg = gtk_file_dialog_new();
    gtk_file_dialog_set_title(dlg, title);
    cg_dlg *d = g_new0(cg_dlg, 1); d->fn = fn; d->data = data; d->folder = folders;
    if (folders) gtk_file_dialog_select_multiple_folders(dlg, GTK_WINDOW(parent), NULL, cg__open_done, d);
    else gtk_file_dialog_open_multiple(dlg, GTK_WINDOW(parent), NULL, cg__open_done, d);
    g_object_unref(dlg);
}
static void cg__folder_done(GObject *src, GAsyncResult *res, gpointer user) {
    cg_dlg *d = user;
    GFile *f = gtk_file_dialog_select_folder_finish(GTK_FILE_DIALOG(src), res, NULL);
    char *p = f ? g_file_get_path(f) : NULL;
    d->fn(p ? p : "", d->data);
    if (p) g_free(p);
    if (f) g_object_unref(f);
    g_free(d);
}
static inline void cg_choose_folder(GtkWidget *parent, const char *title, cg_paths_cb fn, void *data) {
    GtkFileDialog *dlg = gtk_file_dialog_new();
    gtk_file_dialog_set_title(dlg, title);
    cg_dlg *d = g_new0(cg_dlg, 1); d->fn = fn; d->data = data;
    gtk_file_dialog_select_folder(dlg, GTK_WINDOW(parent), NULL, cg__folder_done, d);
    g_object_unref(dlg);
}

// --- Перетаскивание файлов в окно ---
static gboolean cg__drop(GtkDropTarget *t, const GValue *value, double x, double y, gpointer user) {
    cg_dlg *d = user;
    if (!G_VALUE_HOLDS(value, GDK_TYPE_FILE_LIST)) return FALSE;
    GSList *list = g_value_get_boxed(value);
    GString *s = g_string_new(NULL);
    for (GSList *l = list; l; l = l->next) {
        char *p = g_file_get_path(G_FILE(l->data));
        if (p) { if (s->len) g_string_append_c(s, '\n'); g_string_append(s, p); g_free(p); }
    }
    d->fn(s->str, d->data);
    g_string_free(s, TRUE);
    return TRUE;
}
static inline void cg_on_drop_files(GtkWidget *w, cg_paths_cb fn, void *data) {
    GtkDropTarget *t = gtk_drop_target_new(GDK_TYPE_FILE_LIST, GDK_ACTION_COPY);
    cg_dlg *d = g_new0(cg_dlg, 1); d->fn = fn; d->data = data;
    g_signal_connect(t, "drop", G_CALLBACK(cg__drop), d);
    gtk_widget_add_controller(w, GTK_EVENT_CONTROLLER(t));
}

// --- Уведомление внизу окна ---
static inline GtkWidget *cg_toast_overlay(GtkWidget *child) {
    GtkWidget *o = adw_toast_overlay_new();
    adw_toast_overlay_set_child(ADW_TOAST_OVERLAY(o), child);
    return o;
}
static inline void cg_toast(GtkWidget *overlay, const char *text) {
    adw_toast_overlay_add_toast(ADW_TOAST_OVERLAY(overlay), adw_toast_new(text));
}
// --- Открыть папку в файловом менеджере ---
static inline void cg_open_uri(GtkWidget *parent, const char *path) {
    GFile *f = g_file_new_for_path(path);
    GtkFileLauncher *l = gtk_file_launcher_new(f);
    gtk_file_launcher_launch(l, GTK_WINDOW(parent), NULL, NULL, NULL);
    g_object_unref(l); g_object_unref(f);
}
