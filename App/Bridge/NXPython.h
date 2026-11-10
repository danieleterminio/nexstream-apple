#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin Objective-C wrapper around the embedded CPython interpreter (BeeWare Python-Apple-support).
/// Everything crosses the boundary as strings / numbers, the same way the Android app talks to nxbridge.py through Chaquopy.
@interface NXPython : NSObject

/// Starts the interpreter once. `home` is the folder that contains `lib/python3.x`; `paths` are added to `sys.path`.
/// Returns nil on success, an error description otherwise.
+ (nullable NSString *)startWithHome:(NSString *)home paths:(NSArray<NSString *> *)paths;

@property (class, readonly) BOOL isStarted;

/// Calls `module.function(*args)` and returns `str(result)`. Args may be NSString or NSNumber.
/// On a Python exception returns nil and fills `error` with the traceback.
+ (nullable NSString *)call:(NSString *)module function:(NSString *)function args:(NSArray *)args error:(NSString * _Nullable * _Nullable)error;

/// Runs a snippet of Python source (used for small set-up tasks). Returns nil on success, the traceback otherwise.
+ (nullable NSString *)run:(NSString *)source;

@end

NS_ASSUME_NONNULL_END
