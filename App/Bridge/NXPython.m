#import "NXPython.h"
#include <Python/Python.h>

static BOOL nx_started = NO;

@implementation NXPython

+ (BOOL)isStarted { return nx_started; }

+ (nullable NSString *)startWithHome:(NSString *)home paths:(NSArray<NSString *> *)paths {
    @synchronized (self) {
        if (nx_started) return nil;
        PyStatus status;
        PyPreConfig preconfig;
        PyConfig config;

        PyPreConfig_InitIsolatedConfig(&preconfig);
        preconfig.utf8_mode = 1;
        status = Py_PreInitialize(&preconfig);
        if (PyStatus_Exception(status)) {
            return [NSString stringWithFormat:@"preinit: %s", status.err_msg ? status.err_msg : "?"];
        }

        PyConfig_InitIsolatedConfig(&config);
        config.buffered_stdio = 0;
        config.write_bytecode = 0;
        config.install_signal_handlers = 0;

        wchar_t *whome = Py_DecodeLocale([home UTF8String], NULL);
        status = PyConfig_SetString(&config, &config.home, whome);
        PyMem_RawFree(whome);
        if (PyStatus_Exception(status)) {
            PyConfig_Clear(&config);
            return [NSString stringWithFormat:@"home: %s", status.err_msg ? status.err_msg : "?"];
        }
        status = PyConfig_Read(&config);
        if (PyStatus_Exception(status)) {
            PyConfig_Clear(&config);
            return [NSString stringWithFormat:@"read: %s", status.err_msg ? status.err_msg : "?"];
        }
        for (NSString *p in paths) {
            wchar_t *wp = Py_DecodeLocale([p UTF8String], NULL);
            status = PyWideStringList_Append(&config.module_search_paths, wp);
            PyMem_RawFree(wp);
            if (PyStatus_Exception(status)) {
                PyConfig_Clear(&config);
                return [NSString stringWithFormat:@"path: %s", status.err_msg ? status.err_msg : "?"];
            }
        }
        status = Py_InitializeFromConfig(&config);
        PyConfig_Clear(&config);
        if (PyStatus_Exception(status)) {
            return [NSString stringWithFormat:@"init: %s", status.err_msg ? status.err_msg : "?"];
        }
        nx_started = YES;
        // release the GIL: every call takes it again with PyGILState_Ensure, from whatever thread it comes
        PyEval_SaveThread();
        return nil;
    }
}

/// Formats the pending Python exception (clears it). Must be called with the GIL held.
static NSString *nx_fetch_error(void) {
    PyObject *type = NULL, *value = NULL, *tb = NULL;
    PyErr_Fetch(&type, &value, &tb);
    PyErr_NormalizeException(&type, &value, &tb);
    NSString *out = @"Python error";
    PyObject *mod = PyImport_ImportModule("traceback");
    if (mod != NULL) {
        PyObject *list = PyObject_CallMethod(mod, "format_exception", "OOO", type ? type : Py_None, value ? value : Py_None, tb ? tb : Py_None);
        if (list != NULL) {
            PyObject *sep = PyUnicode_FromString("");
            PyObject *joined = PyUnicode_Join(sep, list);
            if (joined != NULL) {
                const char *c = PyUnicode_AsUTF8(joined);
                if (c != NULL) out = [NSString stringWithUTF8String:c] ?: out;
                Py_DECREF(joined);
            }
            Py_XDECREF(sep);
            Py_DECREF(list);
        }
        Py_DECREF(mod);
    }
    PyErr_Clear();
    Py_XDECREF(type); Py_XDECREF(value); Py_XDECREF(tb);
    return out;
}

+ (nullable NSString *)call:(NSString *)module function:(NSString *)function args:(NSArray *)args error:(NSString * _Nullable * _Nullable)error {
    if (!nx_started) { if (error) *error = @"Python not started"; return nil; }
    PyGILState_STATE gil = PyGILState_Ensure();
    NSString *result = nil;
    PyObject *mod = NULL, *fn = NULL, *tuple = NULL, *res = NULL, *str = NULL;

    mod = PyImport_ImportModule([module UTF8String]);
    if (mod == NULL) goto fail;
    fn = PyObject_GetAttrString(mod, [function UTF8String]);
    if (fn == NULL) goto fail;
    tuple = PyTuple_New((Py_ssize_t)args.count);
    if (tuple == NULL) goto fail;
    for (NSUInteger i = 0; i < args.count; i++) {
        id a = args[i];
        PyObject *o = NULL;
        if ([a isKindOfClass:[NSString class]]) {
            o = PyUnicode_FromString([(NSString *)a UTF8String]);
        } else if ([a isKindOfClass:[NSNumber class]]) {
            NSNumber *n = (NSNumber *)a;
            const char *t = [n objCType];
            if (strcmp(t, @encode(double)) == 0 || strcmp(t, @encode(float)) == 0) o = PyFloat_FromDouble([n doubleValue]);
            else o = PyLong_FromLongLong([n longLongValue]);
        } else {
            o = Py_None; Py_INCREF(o);
        }
        if (o == NULL) goto fail;
        PyTuple_SetItem(tuple, (Py_ssize_t)i, o);   // steals the reference
    }
    res = PyObject_CallObject(fn, tuple);
    if (res == NULL) goto fail;
    str = PyObject_Str(res);
    if (str == NULL) goto fail;
    {
        const char *c = PyUnicode_AsUTF8(str);
        if (c == NULL) goto fail;
        result = [NSString stringWithUTF8String:c];
    }
    goto done;

fail:
    {
        NSString *e = nx_fetch_error();
        if (error) *error = e;
    }
done:
    Py_XDECREF(str); Py_XDECREF(res); Py_XDECREF(tuple); Py_XDECREF(fn); Py_XDECREF(mod);
    PyGILState_Release(gil);
    return result;
}

+ (nullable NSString *)run:(NSString *)source {
    if (!nx_started) return @"Python not started";
    PyGILState_STATE gil = PyGILState_Ensure();
    NSString *err = nil;
    if (PyRun_SimpleString([source UTF8String]) != 0) err = @"Python snippet failed";
    PyGILState_Release(gil);
    return err;
}

@end
