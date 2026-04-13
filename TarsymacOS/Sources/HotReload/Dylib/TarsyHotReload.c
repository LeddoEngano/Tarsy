// TarsyHotReload.c
// Injected into iOS Simulator apps via DYLD_INSERT_LIBRARIES.
// Connects to TarsymacOS HotReloadService via Unix domain socket,
// receives compiled dylibs, and patches running code via dyld interposing.
//
// Copyright 2026 Tarsy. MIT License.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <dlfcn.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/time.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/nlist.h>
#include <mach-o/loader.h>

#include "fishhook.h"

#define TARSY_HR_ENV_SOCKET   "TARSY_HOT_RELOAD_SOCKET"
#define TARSY_HR_MAX_LINE     8192
#define TARSY_HR_RECONNECT_MS 1000
#define TARSY_HR_LOG_PREFIX   "[TarsyHotReload] "
#define TARSY_HR_MAX_INTERPOSE 1024

// ── Logging ──

static void tarsy_log(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, TARSY_HR_LOG_PREFIX);
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
}

// ── dyld interposing ──

typedef struct {
    const void *replacement;
    const void *replacee;
} dyld_interpose_tuple;

extern void dyld_dynamic_interpose(
    const struct mach_header *mh,
    const dyld_interpose_tuple array[],
    size_t count
);

// ── Symbol enumeration ──

typedef struct {
    const char *name;
    void *address;
} tarsy_symbol_t;

static int tarsy_get_symbols_from_header(
    const struct mach_header_64 *mh,
    tarsy_symbol_t *out, int max_out
) {
    int count = 0;
    const uint8_t *ptr = (const uint8_t *)mh + sizeof(struct mach_header_64);
    uintptr_t linkedit_base = 0, text_vmaddr = 0;
    const struct symtab_command *symtab_cmd = NULL;

    // First pass: find __TEXT vmaddr, __LINKEDIT, and LC_SYMTAB
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *cmd = (const struct load_command *)ptr;
        if (cmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd;
            if (strcmp(seg->segname, "__TEXT") == 0) text_vmaddr = seg->vmaddr;
            if (strcmp(seg->segname, "__LINKEDIT") == 0)
                linkedit_base = (uintptr_t)mh + seg->vmaddr - seg->fileoff - text_vmaddr;
        }
        if (cmd->cmd == LC_SYMTAB) symtab_cmd = (const struct symtab_command *)cmd;
        ptr += cmd->cmdsize;
    }

    if (!symtab_cmd || linkedit_base == 0) return 0;

    const struct nlist_64 *symlist = (const struct nlist_64 *)(linkedit_base + symtab_cmd->symoff);
    const char *strtab = (const char *)(linkedit_base + symtab_cmd->stroff);
    uintptr_t slide = (uintptr_t)mh - text_vmaddr;

    for (uint32_t s = 0; s < symtab_cmd->nsyms && count < max_out; s++) {
        const struct nlist_64 *sym = &symlist[s];
        if ((sym->n_type & N_TYPE) != N_SECT) continue;
        if (sym->n_un.n_strx == 0) continue;

        const char *name = strtab + sym->n_un.n_strx;
        if (name[0] == '\0') continue;

        const char *clean = (name[0] == '_') ? name + 1 : name;
        out[count].name = clean;
        out[count].address = (void *)(sym->n_value + slide);
        count++;
    }
    return count;
}

// ── Main injection ──

static int tarsy_inject_dylib(const char *dylib_path, char *out_classes, size_t out_len) {
    int patched = 0;
    int interposed = 0;
    out_classes[0] = '\0';

    // Phase 1: ObjC class patching
    unsigned int pre_count = 0;
    Class *pre_classes = objc_copyClassList(&pre_count);

    void *handle = dlopen(dylib_path, RTLD_NOW);
    if (!handle) {
        tarsy_log("dlopen failed: %s", dlerror());
        free(pre_classes);
        return -1;
    }

    unsigned int post_count = 0;
    Class *post_classes = objc_copyClassList(&post_count);

    for (unsigned int i = 0; i < post_count; i++) {
        Class nc = post_classes[i];
        int found = 0;
        for (unsigned int j = 0; j < pre_count; j++) {
            if (pre_classes[j] == nc) { found = 1; break; }
        }
        if (found) continue;

        const char *name = class_getName(nc);
        if (!name) continue;
        Class orig = objc_getClass(name);
        if (!orig || orig == nc) continue;

        unsigned int mc = 0;
        Method *methods = class_copyMethodList(nc, &mc);
        for (unsigned int m = 0; m < mc; m++)
            class_replaceMethod(orig, method_getName(methods[m]),
                method_getImplementation(methods[m]), method_getTypeEncoding(methods[m]));
        free(methods);

        Class om = object_getClass((id)orig);
        Class nm = object_getClass((id)nc);
        if (om && nm && om != nm) {
            unsigned int mc2 = 0;
            Method *mm = class_copyMethodList(nm, &mc2);
            for (unsigned int m = 0; m < mc2; m++)
                class_replaceMethod(om, method_getName(mm[m]),
                    method_getImplementation(mm[m]), method_getTypeEncoding(mm[m]));
            free(mm);
        }

        if (patched > 0 && strlen(out_classes) + 1 < out_len) strcat(out_classes, ",");
        if (strlen(out_classes) + strlen(name) < out_len) strcat(out_classes, name);
        patched++;
    }
    free(pre_classes);
    free(post_classes);

    // Phase 2: Swift function interposing via dyld_dynamic_interpose
    // Uses dlsym(RTLD_MAIN_ONLY) to find originals — requires -enable-testing
    uint32_t image_count = _dyld_image_count();

    // Find the new dylib's header
    const struct mach_header_64 *new_mh = NULL;
    const char *basename = strrchr(dylib_path, '/');
    basename = basename ? basename + 1 : dylib_path;
    for (uint32_t i = image_count; i > 0; i--) {
        const char *img = _dyld_get_image_name(i - 1);
        if (img && strstr(img, basename)) {
            new_mh = (const struct mach_header_64 *)_dyld_get_image_header(i - 1);
            break;
        }
    }

    if (new_mh) {
        tarsy_symbol_t *syms = (tarsy_symbol_t *)calloc(TARSY_HR_MAX_INTERPOSE, sizeof(tarsy_symbol_t));
        int sym_count = tarsy_get_symbols_from_header(new_mh, syms, TARSY_HR_MAX_INTERPOSE);
        tarsy_log("New dylib: %d symbols", sym_count);

        dyld_interpose_tuple *tuples = (dyld_interpose_tuple *)calloc(sym_count, sizeof(dyld_interpose_tuple));
        int tuple_count = 0;

        for (int s = 0; s < sym_count; s++) {
            void *orig = dlsym(RTLD_MAIN_ONLY, syms[s].name);
            if (!orig || orig == syms[s].address) continue;
            tuples[tuple_count].replacement = syms[s].address;
            tuples[tuple_count].replacee = orig;
            tuple_count++;
        }

        tarsy_log("Interposing %d symbols", tuple_count);

        if (tuple_count > 0) {
            for (uint32_t i = 0; i < image_count; i++) {
                const struct mach_header *mh = _dyld_get_image_header(i);
                if (mh && mh != (const struct mach_header *)new_mh)
                    dyld_dynamic_interpose(mh, tuples, tuple_count);
            }
            interposed = tuple_count;
            tarsy_log("Interposed %d functions across %d images", tuple_count, image_count);
        }

        free(tuples);
        free(syms);
    }

    // Phase 3: Trigger SwiftUI re-render
    dispatch_async(dispatch_get_main_queue(), ^{
        // Post notification
        Class NC = objc_getClass("NSNotificationCenter");
        if (NC) {
            id center = ((id(*)(Class, SEL))objc_msgSend)(NC, sel_registerName("defaultCenter"));
            if (center) {
                id name = ((id(*)(Class, SEL, const char*))objc_msgSend)(
                    objc_getClass("NSString"), sel_registerName("stringWithUTF8String:"),
                    "TarsyHotReloadInjection");
                ((void(*)(id, SEL, id, id, id))objc_msgSend)(
                    center, sel_registerName("postNotificationName:object:userInfo:"),
                    name, NULL, NULL);
            }
        }

        // Dump available invalidation methods on the hosting controller,
        // then try each one to force SwiftUI re-render.
        Class UIApp = objc_getClass("UIApplication");
        if (UIApp) {
            id app = ((id(*)(Class, SEL))objc_msgSend)(UIApp, sel_registerName("sharedApplication"));
            id scenes = ((id(*)(id, SEL))objc_msgSend)(app, sel_registerName("connectedScenes"));
            id arr = ((id(*)(id, SEL))objc_msgSend)(scenes, sel_registerName("allObjects"));
            unsigned long n = ((unsigned long(*)(id, SEL))objc_msgSend)(arr, sel_registerName("count"));
            for (unsigned long i = 0; i < n; i++) {
                id scene = ((id(*)(id, SEL, unsigned long))objc_msgSend)(arr, sel_registerName("objectAtIndex:"), i);
                id wins = ((id(*)(id, SEL))objc_msgSend)(scene, sel_registerName("windows"));
                if (!wins) continue;
                unsigned long wn = ((unsigned long(*)(id, SEL))objc_msgSend)(wins, sel_registerName("count"));
                for (unsigned long w = 0; w < wn; w++) {
                    id win = ((id(*)(id, SEL, unsigned long))objc_msgSend)(wins, sel_registerName("objectAtIndex:"), w);
                    id vc = ((id(*)(id, SEL))objc_msgSend)(win, sel_registerName("rootViewController"));
                    if (!vc) continue;

                    tarsy_log("Functions interposed — requesting app relaunch for UI update");
                }
            }
        }
        tarsy_log("Method dump complete");
    });

    return patched + interposed;
}

// ── Socket communication ──

static int tarsy_connect_socket(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { close(fd); return -1; }
    return fd;
}

static int tarsy_send_line(int fd, const char *line) {
    size_t len = strlen(line);
    ssize_t sent = 0;
    while (sent < (ssize_t)len) {
        ssize_t n = write(fd, line + sent, len - sent);
        if (n <= 0) return -1;
        sent += n;
    }
    return 0;
}

static int tarsy_read_line(int fd, char *buf, size_t sz) {
    size_t pos = 0;
    while (pos < sz - 1) {
        char c;
        ssize_t n = read(fd, &c, 1);
        if (n <= 0) return -1;
        if (c == '\n') { buf[pos] = '\0'; return (int)pos; }
        buf[pos++] = c;
    }
    buf[pos] = '\0';
    return (int)pos;
}

// ── Client thread ──

static void *tarsy_client_thread(void *arg) {
    const char *socket_path = (const char *)arg;
    char line[TARSY_HR_MAX_LINE];
    char response[TARSY_HR_MAX_LINE];
    char classes_buf[4096];

    tarsy_log("Client thread started, socket: %s", socket_path);

    while (1) {
        int fd = tarsy_connect_socket(socket_path);
        if (fd < 0) { usleep(TARSY_HR_RECONNECT_MS * 1000); continue; }

        tarsy_log("Connected to HotReloadService");
        tarsy_send_line(fd, "CONNECTED\n");

        while (1) {
            int len = tarsy_read_line(fd, line, sizeof(line));
            if (len < 0) { tarsy_log("Connection lost"); break; }

            if (strncmp(line, "PING", 4) == 0) { tarsy_send_line(fd, "PONG\n"); continue; }

            if (strncmp(line, "LOAD ", 5) == 0) {
                const char *path = line + 5;
                tarsy_log("Loading: %s", path);

                struct timeval t0, t1;
                gettimeofday(&t0, NULL);
                int result = tarsy_inject_dylib(path, classes_buf, sizeof(classes_buf));
                gettimeofday(&t1, NULL);
                long ms = (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_usec - t0.tv_usec) / 1000;

                if (result >= 0) {
                    const char *fn = strrchr(path, '/');
                    fn = fn ? fn + 1 : path;
                    snprintf(response, sizeof(response), "OK file=%s classes=%s count=%d duration=%ld\n",
                             fn, strlen(classes_buf) > 0 ? classes_buf : "none", result, ms);
                    tarsy_log("OK: %d patched in %ldms", result, ms);
                } else {
                    snprintf(response, sizeof(response), "ERROR %s\n", dlerror() ?: "unknown");
                    tarsy_log("FAILED: %s", dlerror() ?: "unknown");
                }
                tarsy_send_line(fd, response);
                continue;
            }
        }
        close(fd);
        usleep(TARSY_HR_RECONNECT_MS * 1000);
    }
    return NULL;
}

// ── Constructor ──

__attribute__((constructor))
static void tarsy_hotreload_init(void) {
    const char *path = getenv(TARSY_HR_ENV_SOCKET);
    if (!path || !*path) return;

    tarsy_log("Init pid=%d socket=%s", getpid(), path);
    char *copy = strdup(path);
    if (!copy) return;

    pthread_t t;
    pthread_attr_t a;
    pthread_attr_init(&a);
    pthread_attr_setdetachstate(&a, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&t, &a, tarsy_client_thread, copy) != 0) free(copy);
    pthread_attr_destroy(&a);
}
