#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Looks up a source key, with English as the resource fallback.
FOUNDATION_EXPORT NSString *QBLocalized(NSString *key);
/// The resolved language used for the current process.
FOUNDATION_EXPORT NSString *QBCurrentLanguage(void);
FOUNDATION_EXPORT NSArray<NSString *> *QBSupportedLanguages(void);
/// The saved choice: "system" or a supported language code. This never writes defaults.
FOUNDATION_EXPORT NSString *QBPreferredLanguage(void);
/// A process-only preview. Passing nil clears it; this never writes defaults.
FOUNDATION_EXPORT void QBSetLanguageOverride(NSString * _Nullable code);
/// Saves an explicit UI choice under QuietBarLanguage.
FOUNDATION_EXPORT void QBSetPreferredLanguage(NSString *code);
/// Resource, format, resolution, and fallback checks; no UI, capture, or preference writes.
FOUNDATION_EXPORT NSDictionary *QBLocalizationSelfTest(void);

NS_ASSUME_NONNULL_END
