#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include <glib/gstdio.h>
#ifdef HAVE_AYATANA
#include <libayatana-appindicator/app-indicator.h>
#else
#include <libappindicator/app-indicator.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  GtkWindow* window;
  FlMethodChannel* tray_channel;
  AppIndicator* tray_indicator;
  gchar* tray_icon_path_off;
  gchar* tray_icon_path_on;
  gchar* tray_icon_name_off;
  gchar* tray_icon_name_on;
  GtkWidget* tray_menu;
  GtkWidget* tray_item_show;
  GtkWidget* tray_item_disconnect;
  GtkWidget* tray_item_proxy;
  GtkWidget* tray_item_vpn;
  GtkWidget* tray_item_exit;
  gboolean tray_connected;
  gboolean tray_has_target;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static gboolean ensure_tray_icon_paths(gchar** off_path, gchar** on_path) {
  const gchar* cache_dir = g_get_user_cache_dir();
  if (cache_dir == nullptr) {
    return FALSE;
  }

  g_autofree gchar* dir = g_build_filename(cache_dir, "pingtunnel-client", nullptr);
  if (g_mkdir_with_parents(dir, 0755) != 0) {
    return FALSE;
  }

  g_autofree gchar* off_path_local = g_build_filename(dir, "tray-ping-off.svg", nullptr);
  g_autofree gchar* on_path_local = g_build_filename(dir, "tray-ping-on.svg", nullptr);
  static const gchar* kSvgIconOff =
      R"svg(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><g fill="#fff" transform="translate(4.8 0) scale(1.0666667)"><path d="M21,10.5C21,4.7,16.3,0,10.5,0S0,4.7,0,10.5c0,2.457,0.85,4.711,2.264,6.5h16.473C20.15,15.211,21,12.957,21,10.5z"/><path d="M17.843,18H3.157c1.407,1.377,3.199,2.361,5.2,2.777l-0.764,7.865c-0.038,0.346,0.072,0.691,0.305,0.95C8.13,29.852,8.461,30,8.809,30h3.381c0.348,0,0.679-0.148,0.91-0.407c0.232-0.259,0.343-0.604,0.305-0.95l-0.764-7.864C14.643,20.362,16.436,19.378,17.843,18z"/><circle cx="18.999" cy="24" r="2"/></g></svg>)svg";
  static const gchar* kSvgIconOn =
      R"svg(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><g fill="#4caf50" transform="translate(4.8 0) scale(1.0666667)"><path d="M21,10.5C21,4.7,16.3,0,10.5,0S0,4.7,0,10.5c0,2.457,0.85,4.711,2.264,6.5h16.473C20.15,15.211,21,12.957,21,10.5z"/><path d="M17.843,18H3.157c1.407,1.377,3.199,2.361,5.2,2.777l-0.764,7.865c-0.038,0.346,0.072,0.691,0.305,0.95C8.13,29.852,8.461,30,8.809,30h3.381c0.348,0,0.679-0.148,0.91-0.407c0.232-0.259,0.343-0.604,0.305-0.95l-0.764-7.864C14.643,20.362,16.436,19.378,17.843,18z"/><circle cx="18.999" cy="24" r="2"/></g></svg>)svg";

  g_autoptr(GError) error = nullptr;
  if (!g_file_set_contents(off_path_local, kSvgIconOff, -1, &error)) {
    return FALSE;
  }
  if (!g_file_set_contents(on_path_local, kSvgIconOn, -1, &error)) {
    return FALSE;
  }

  *off_path = g_strdup(off_path_local);
  *on_path = g_strdup(on_path_local);
  return TRUE;
}

static gchar* icon_name_without_extension(const gchar* icon_path) {
  if (icon_path == nullptr) {
    return nullptr;
  }
  g_autofree gchar* icon_name = g_path_get_basename(icon_path);
  gchar* dot = g_strrstr(icon_name, ".");
  if (dot != nullptr) {
    *dot = '\0';
  }
  return g_strdup(icon_name);
}

static void present_window(MyApplication* self) {
  if (self->window == nullptr) {
    return;
  }

  gtk_widget_show(GTK_WIDGET(self->window));
  gtk_window_present(self->window);
}

static void send_tray_event(MyApplication* self, const gchar* event_name) {
  if (self->tray_channel == nullptr) {
    return;
  }

  g_autoptr(FlValue) payload = fl_value_new_map();
  fl_value_set_string_take(payload, "event", fl_value_new_string(event_name));
  fl_method_channel_invoke_method(self->tray_channel, "onTrayEvent", payload,
                                  nullptr, nullptr, nullptr);
}

static void on_tray_show_activate(GtkMenuItem* item, gpointer user_data) {
  (void)item;
  MyApplication* self = MY_APPLICATION(user_data);
  present_window(self);
  send_tray_event(self, "show");
}

static void on_tray_disconnect_activate(GtkMenuItem* item, gpointer user_data) {
  (void)item;
  MyApplication* self = MY_APPLICATION(user_data);
  if (self->tray_connected) {
    send_tray_event(self, "disconnect");
  } else {
    send_tray_event(self, "connect");
  }
}

static void on_tray_switch_proxy_activate(GtkMenuItem* item, gpointer user_data) {
  (void)item;
  MyApplication* self = MY_APPLICATION(user_data);
  send_tray_event(self, "switch_proxy");
}

static void on_tray_switch_vpn_activate(GtkMenuItem* item, gpointer user_data) {
  (void)item;
  MyApplication* self = MY_APPLICATION(user_data);
  send_tray_event(self, "switch_vpn");
}

static void on_tray_exit_activate(GtkMenuItem* item, gpointer user_data) {
  (void)item;
  MyApplication* self = MY_APPLICATION(user_data);
  send_tray_event(self, "exit");
}

static void initialize_tray(MyApplication* self) {
  if (self->tray_indicator != nullptr) {
    return;
  }

  self->tray_menu = gtk_menu_new();
  self->tray_item_show = gtk_menu_item_new_with_label("Show");
  GtkWidget* separator_one = gtk_separator_menu_item_new();
  self->tray_item_disconnect = gtk_menu_item_new_with_label("Disconnect");
  self->tray_item_proxy = gtk_menu_item_new_with_label("Switch to Proxy");
  self->tray_item_vpn = gtk_menu_item_new_with_label("Switch to VPN");
  GtkWidget* separator_two = gtk_separator_menu_item_new();
  self->tray_item_exit = gtk_menu_item_new_with_label("Exit");

  gtk_menu_shell_append(GTK_MENU_SHELL(self->tray_menu), self->tray_item_show);
  gtk_menu_shell_append(GTK_MENU_SHELL(self->tray_menu), separator_one);
  gtk_menu_shell_append(GTK_MENU_SHELL(self->tray_menu), self->tray_item_disconnect);
  gtk_menu_shell_append(GTK_MENU_SHELL(self->tray_menu), self->tray_item_proxy);
  gtk_menu_shell_append(GTK_MENU_SHELL(self->tray_menu), self->tray_item_vpn);
  gtk_menu_shell_append(GTK_MENU_SHELL(self->tray_menu), separator_two);
  gtk_menu_shell_append(GTK_MENU_SHELL(self->tray_menu), self->tray_item_exit);

  g_signal_connect(self->tray_item_show, "activate",
                   G_CALLBACK(on_tray_show_activate), self);
  g_signal_connect(self->tray_item_disconnect, "activate",
                   G_CALLBACK(on_tray_disconnect_activate), self);
  g_signal_connect(self->tray_item_proxy, "activate",
                   G_CALLBACK(on_tray_switch_proxy_activate), self);
  g_signal_connect(self->tray_item_vpn, "activate",
                   G_CALLBACK(on_tray_switch_vpn_activate), self);
  g_signal_connect(self->tray_item_exit, "activate",
                   G_CALLBACK(on_tray_exit_activate), self);

  gtk_widget_set_sensitive(self->tray_item_disconnect, FALSE);
  gtk_widget_set_sensitive(self->tray_item_proxy, FALSE);
  gtk_widget_set_sensitive(self->tray_item_vpn, FALSE);

  gtk_widget_show_all(self->tray_menu);

  if (ensure_tray_icon_paths(&self->tray_icon_path_off, &self->tray_icon_path_on)) {
    self->tray_icon_name_off = icon_name_without_extension(self->tray_icon_path_off);
    self->tray_icon_name_on = icon_name_without_extension(self->tray_icon_path_on);
    if (self->tray_icon_name_on == nullptr && self->tray_icon_name_off != nullptr) {
      self->tray_icon_name_on = g_strdup(self->tray_icon_name_off);
    }
  }

  if (self->tray_icon_path_off != nullptr && self->tray_icon_name_off != nullptr) {
    g_autofree gchar* icon_dir = g_path_get_dirname(self->tray_icon_path_off);
    self->tray_indicator = app_indicator_new_with_path(
        "pingtunnel-client", self->tray_icon_name_off,
        APP_INDICATOR_CATEGORY_APPLICATION_STATUS,
        icon_dir);
    app_indicator_set_icon_theme_path(self->tray_indicator, icon_dir);
    app_indicator_set_icon(self->tray_indicator, self->tray_icon_name_off);
  } else {
    self->tray_indicator =
        app_indicator_new("pingtunnel-client", "application-x-executable",
                          APP_INDICATOR_CATEGORY_APPLICATION_STATUS);
  }

  app_indicator_set_status(self->tray_indicator, APP_INDICATOR_STATUS_ACTIVE);
  app_indicator_set_menu(self->tray_indicator, GTK_MENU(self->tray_menu));
  app_indicator_set_title(self->tray_indicator, "");
  app_indicator_set_label(self->tray_indicator, "", "");
  app_indicator_set_secondary_activate_target(self->tray_indicator,
                                              self->tray_item_show);
}

static FlMethodResponse* update_tray_state(MyApplication* self, FlValue* args) {
  gboolean connected = FALSE;
  gboolean has_target = FALSE;
  const gchar* mode = "none";

  if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
    FlValue* connected_value = fl_value_lookup_string(args, "connected");
    if (connected_value != nullptr) {
      connected = fl_value_get_bool(connected_value);
    }

    FlValue* has_target_value = fl_value_lookup_string(args, "hasTarget");
    if (has_target_value != nullptr) {
      has_target = fl_value_get_bool(has_target_value);
    }

    FlValue* mode_value = fl_value_lookup_string(args, "mode");
    if (mode_value != nullptr) {
      mode = fl_value_get_string(mode_value);
    }
  }

  self->tray_connected = connected;
  self->tray_has_target = has_target;
  if (self->tray_indicator != nullptr && self->tray_icon_name_off != nullptr) {
    const gchar* icon_name =
        connected && self->tray_icon_name_on != nullptr
            ? self->tray_icon_name_on
            : self->tray_icon_name_off;
    app_indicator_set_icon(self->tray_indicator, icon_name);
  }

  if (self->tray_item_disconnect != nullptr) {
    gtk_menu_item_set_label(GTK_MENU_ITEM(self->tray_item_disconnect),
                            connected ? "Disconnect" : "Connect");
    gtk_widget_set_sensitive(self->tray_item_disconnect, connected || has_target);
  }
  if (self->tray_item_proxy != nullptr) {
    gtk_widget_set_sensitive(self->tray_item_proxy,
                             has_target && g_strcmp0(mode, "proxy") != 0);
  }
  if (self->tray_item_vpn != nullptr) {
    gtk_widget_set_sensitive(self->tray_item_vpn,
                             has_target && g_strcmp0(mode, "vpn") != 0);
  }

  return FL_METHOD_RESPONSE(
      fl_method_success_response_new(fl_value_new_bool(TRUE)));
}

static FlMethodResponse* exit_now(MyApplication* self) {
  if (self->tray_indicator != nullptr) {
    app_indicator_set_status(self->tray_indicator, APP_INDICATOR_STATUS_PASSIVE);
  }
  g_application_quit(G_APPLICATION(self));
  return FL_METHOD_RESPONSE(
      fl_method_success_response_new(fl_value_new_bool(TRUE)));
}

static FlMethodResponse* show_window(MyApplication* self) {
  present_window(self);
  return FL_METHOD_RESPONSE(
      fl_method_success_response_new(fl_value_new_bool(TRUE)));
}

static void tray_method_call_handler(FlMethodChannel* channel,
                                     FlMethodCall* method_call,
                                     gpointer user_data) {
  (void)channel;
  MyApplication* self = MY_APPLICATION(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  g_autoptr(FlMethodResponse) response = nullptr;
  if (strcmp(method, "updateState") == 0) {
    response = update_tray_state(self, args);
  } else if (strcmp(method, "exitNow") == 0) {
    response = exit_now(self);
  } else if (strcmp(method, "showWindow") == 0) {
    response = show_window(self);
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

static void initialize_tray_channel(MyApplication* self, FlView* view) {
  if (self->tray_channel != nullptr) {
    return;
  }

  FlEngine* engine = fl_view_get_engine(view);
  FlBinaryMessenger* messenger = fl_engine_get_binary_messenger(engine);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();

  self->tray_channel = fl_method_channel_new(messenger, "pingtunnel_tray_linux",
                                             FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->tray_channel, tray_method_call_handler, g_object_ref(self),
      g_object_unref);
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  (void)self;
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  if (self->window != nullptr) {
    present_window(self);
    return;
  }

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  self->window = window;
  g_object_add_weak_pointer(G_OBJECT(window), reinterpret_cast<gpointer*>(&self->window));

  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Pingtunnel Client");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Pingtunnel Client");
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  initialize_tray_channel(self, view);
  initialize_tray(self);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  if (self->tray_indicator != nullptr) {
    app_indicator_set_status(self->tray_indicator, APP_INDICATOR_STATUS_PASSIVE);
  }
  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_pointer(&self->tray_icon_path_off, g_free);
  g_clear_pointer(&self->tray_icon_path_on, g_free);
  g_clear_pointer(&self->tray_icon_name_off, g_free);
  g_clear_pointer(&self->tray_icon_name_on, g_free);
  g_clear_object(&self->tray_channel);
  g_clear_object(&self->tray_indicator);

  self->tray_menu = nullptr;
  self->tray_item_show = nullptr;
  self->tray_item_disconnect = nullptr;
  self->tray_item_proxy = nullptr;
  self->tray_item_vpn = nullptr;
  self->tray_item_exit = nullptr;

  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {
  self->window = nullptr;
  self->tray_channel = nullptr;
  self->tray_indicator = nullptr;
  self->tray_icon_path_off = nullptr;
  self->tray_icon_path_on = nullptr;
  self->tray_icon_name_off = nullptr;
  self->tray_icon_name_on = nullptr;
  self->tray_menu = nullptr;
  self->tray_item_show = nullptr;
  self->tray_item_disconnect = nullptr;
  self->tray_item_proxy = nullptr;
  self->tray_item_vpn = nullptr;
  self->tray_item_exit = nullptr;
  self->tray_connected = FALSE;
  self->tray_has_target = FALSE;
}

MyApplication* my_application_new() {
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_DEFAULT_FLAGS, nullptr));
}
