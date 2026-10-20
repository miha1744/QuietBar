#import "QBLocalization.h"
#import <dispatch/dispatch.h>

static NSString *const QBLanguagePreferenceKey = @"QuietBarLanguage";
static NSString *QBLanguageOverride;

static NSObject *QBLocalizationLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

NSArray<NSString *> *QBSupportedLanguages(void) {
    return @[@"en", @"ru", @"de", @"es", @"fr", @"zh-Hans"];
}

// Deliberately do not resolve Traditional Chinese to Simplified Chinese.
static NSString *QBCanonicalLanguage(NSString *code) {
    if (![code isKindOfClass:NSString.class]) return nil;
    NSString *normalized = [[code stringByReplacingOccurrencesOfString:@"_" withString:@"-"] lowercaseString];
    NSArray<NSString *> *parts = [normalized componentsSeparatedByString:@"-"];
    NSString *base = parts.firstObject;
    if ([base isEqualToString:@"zh"]) {
        if ([parts containsObject:@"hant"] || [parts containsObject:@"tw"] ||
            [parts containsObject:@"hk"] || [parts containsObject:@"mo"]) return nil;
        return @"zh-Hans";
    }
    if ([@[@"en", @"ru", @"de", @"es", @"fr"] containsObject:base]) return base;
    return nil;
}

static NSString *QBResolveLanguages(NSArray<NSString *> *preferred) {
    for (NSString *code in preferred) {
        NSString *resolved = QBCanonicalLanguage(code);
        if (resolved) return resolved;
    }
    return @"en";
}

static NSString *QBValidatedChoice(NSString *code) {
    return [QBSupportedLanguages() containsObject:code] ? code : @"system";
}

NSString *QBPreferredLanguage(void) {
    id saved = [NSUserDefaults.standardUserDefaults objectForKey:QBLanguagePreferenceKey];
    return [saved isKindOfClass:NSString.class] ? QBValidatedChoice(saved) : @"system";
}

NSString *QBCurrentLanguage(void) {
    NSString *choice;
    @synchronized (QBLocalizationLock()) {
        choice = QBLanguageOverride ?: QBPreferredLanguage();
    }
    return [choice isEqualToString:@"system"] ? QBResolveLanguages(NSLocale.preferredLanguages) : choice;
}

void QBSetLanguageOverride(NSString *code) {
    @synchronized (QBLocalizationLock()) {
        QBLanguageOverride = code ? [QBValidatedChoice(code) copy] : nil;
    }
}

void QBSetPreferredLanguage(NSString *code) {
    [NSUserDefaults.standardUserDefaults setObject:QBValidatedChoice(code) forKey:QBLanguagePreferenceKey];
}

static NSDictionary<NSString *, NSURL *> *QBLocalizationURLs(void) {
    static NSDictionary *urls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *found = [NSMutableDictionary dictionary];
        NSURL *resources = NSBundle.mainBundle.resourceURL;
        for (NSString *language in QBSupportedLanguages()) {
            // Use the exact language directory so a bundle's implicit fallback cannot mask a missing file.
            NSURL *url = [[resources URLByAppendingPathComponent:[language stringByAppendingString:@".lproj"]
                                                    isDirectory:YES]
                          URLByAppendingPathComponent:@"Localizable.strings"];
            if (url && [NSFileManager.defaultManager isReadableFileAtPath:url.path]) found[language] = url;
        }
        urls = [found copy];
    });
    return urls;
}

static NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *QBLocalizationCatalogs(void) {
    static NSDictionary *catalogs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *loaded = [NSMutableDictionary dictionary];
        [QBLocalizationURLs() enumerateKeysAndObjectsUsingBlock:^(NSString *language, NSURL *url, BOOL *stop) {
            (void)stop;
            NSString *contents = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:NULL];
            if (!contents) return;
            @try {
                id parsed = contents.propertyListFromStringsFileFormat;
                if ([parsed isKindOfClass:NSDictionary.class]) loaded[language] = parsed;
            } @catch (NSException *exception) { (void)exception; }
        }];
        catalogs = [loaded copy];
    });
    return catalogs;
}

static NSString *QBTranslation(NSString *key, NSString *language,
                               NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *catalogs) {
    id translated = catalogs[language][key];
    if ([translated isKindOfClass:NSString.class] && [translated length]) return translated;
    id english = catalogs[@"en"][key];
    return [english isKindOfClass:NSString.class] && [english length] ? english : key;
}

static NSDictionary<NSString *, id> *QBReverseLocalization(void) {
    static NSDictionary *reverse;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        for (NSDictionary *catalog in QBLocalizationCatalogs().allValues) {
            [catalog enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
                (void)stop;
                if (![key isKindOfClass:NSString.class] || ![value isKindOfClass:NSString.class]) return;
                id existing = result[value];
                if (!existing) result[value] = key;
                else if (![existing isEqual:key]) result[value] = NSNull.null;
            }];
        }
        reverse = [result copy];
    });
    return reverse;
}

NSString *QBLocalized(NSString *key) {
    if (!key.length) return key ?: @"";
    NSDictionary *catalogs = QBLocalizationCatalogs();
    NSString *source = key;
    if (!catalogs[@"en"][source]) {
        id reversed = QBReverseLocalization()[key];
        if ([reversed isKindOfClass:NSString.class]) source = reversed;
    }
    return QBTranslation(source, QBCurrentLanguage(), catalogs);
}

static NSArray<NSString *> *QBFormatTokens(NSString *string) {
    static NSRegularExpression *expression;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        expression = [NSRegularExpression regularExpressionWithPattern:
            @"%(?:%|(?:[1-9][0-9]*\\$)?[-+ #0']*(?:[0-9]+|\\*(?:[1-9][0-9]*\\$)?)?(?:\\.(?:[0-9]+|\\*(?:[1-9][0-9]*\\$)?))?(?:hh|ll|h|l|j|z|t|L|q)?[@diouxXfFeEgGaAcCsSpn])"
            options:0 error:NULL];
    });
    NSMutableArray *tokens = [NSMutableArray array];
    for (NSTextCheckingResult *match in [expression matchesInString:string options:0 range:NSMakeRange(0, string.length)]) {
        [tokens addObject:[string substringWithRange:match.range]];
    }
    return tokens;
}

NSDictionary *QBLocalizationSelfTest(void) {
    NSMutableArray<NSString *> *errors = [NSMutableArray array];
    NSDictionary *catalogs = QBLocalizationCatalogs();
    NSDictionary *english = catalogs[@"en"];
    NSSet *expected = [NSSet setWithArray:english.allKeys ?: @[]];
    if (!expected.count) [errors addObject:@"English catalog is missing or empty"];
    NSMutableDictionary *resources = [NSMutableDictionary dictionary];
    for (NSString *language in QBSupportedLanguages()) {
        NSURL *url = QBLocalizationURLs()[language];
        resources[language] = url.path ?: @"";
        NSDictionary *catalog = catalogs[language];
        if (!url) [errors addObject:[NSString stringWithFormat:@"Missing resource: %@", language]];
        if (!catalog) { [errors addObject:[NSString stringWithFormat:@"Unreadable catalog: %@", language]]; continue; }
        if (![[NSSet setWithArray:catalog.allKeys] isEqual:expected])
            [errors addObject:[NSString stringWithFormat:@"Unequal key set: %@", language]];
        for (id key in catalog) {
            id value = catalog[key];
            if (![key isKindOfClass:NSString.class] || ![value isKindOfClass:NSString.class] ||
                ![[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] length]) {
                [errors addObject:[NSString stringWithFormat:@"Invalid or empty translation: %@ / %@", language, key]];
                continue;
            }
            if (![QBFormatTokens(key) isEqual:QBFormatTokens(value)])
                [errors addObject:[NSString stringWithFormat:@"Format mismatch: %@ / %@", language, key]];
        }
    }
    NSDictionary *knownLabels = @{@"en":@"Interface language", @"ru":@"Язык интерфейса",
        @"de":@"Sprache der Benutzeroberfläche", @"es":@"Idioma de la interfaz",
        @"fr":@"Langue de l’interface", @"zh-Hans":@"界面语言"};
    for (NSString *language in QBSupportedLanguages()) {
        if (![catalogs[language][@"Язык интерфейса"] isEqual:knownLabels[language]])
            [errors addObject:[NSString stringWithFormat:@"Known label mismatch: %@", language]];
        if (![QBResolveLanguages(@[language]) isEqual:language])
            [errors addObject:[NSString stringWithFormat:@"Language resolution mismatch: %@", language]];
    }
    NSArray *resolutionCases = @[@[@[@"pt-BR"], @"en"], @[@[@"it", @"fr-CA"], @"fr"],
        @[@[@"ru_RU"], @"ru"], @[@[@"zh-CN"], @"zh-Hans"], @[@[@"zh-Hans-CN"], @"zh-Hans"],
        @[@[@"zh-Hant-TW", @"de-DE"], @"de"], @[@[], @"en"]];
    for (NSArray *test in resolutionCases) {
        if (![QBResolveLanguages(test[0]) isEqual:test[1]]) [errors addObject:@"Preferred language fallback mismatch"];
    }
    NSDictionary *fallbackCatalogs = @{@"en":@{@"known":@"English fallback"}, @"ru":@{}};
    if (![QBTranslation(@"known", @"ru", fallbackCatalogs) isEqual:@"English fallback"] ||
        ![QBTranslation(@"unknown", @"ru", fallbackCatalogs) isEqual:@"unknown"])
        [errors addObject:@"Missing-key fallback mismatch"];
    if (![QBFormatTokens(@"%@ %u %ld %% %1$@ %02d") isEqual:@[@"%@", @"%u", @"%ld", @"%%", @"%1$@", @"%02d"]])
        [errors addObject:@"Format token parser mismatch"];

    // Exercise the public API with an in-process override and restore it even if a check fails.
    // No controller state, process, or saved language preference is changed by these checks.
    NSString *previousOverride;
    @synchronized (QBLocalizationLock()) { previousOverride = [QBLanguageOverride copy]; }
    id previousPreference = [NSUserDefaults.standardUserDefaults objectForKey:QBLanguagePreferenceKey];
    @try {
        NSArray *messageKeys = @[@"Язык интерфейса", @"Приложение запущено",
            @"Журнал приложения повреждён или не прошёл проверку владельца. Автоматические действия остановлены."];
        NSString *formatKey = @"Выбрано: %@. Закройте приложение и нажмите «Запустить через QuietBar».";
        NSString *sampleName = @"Capture 研究 100% 'test'";
        for (NSString *language in QBSupportedLanguages()) {
            QBSetLanguageOverride(language);
            if (![QBCurrentLanguage() isEqual:language])
                [errors addObject:[NSString stringWithFormat:@"Override resolution mismatch: %@", language]];
            for (NSString *key in messageKeys) {
                NSString *value = QBLocalized(key);
                if (![value isEqual:catalogs[language][key]] ||
                    (![language isEqual:@"ru"] && [value isEqual:key]))
                    [errors addObject:[NSString stringWithFormat:@"Live message translation mismatch: %@ / %@", language, key]];
            }
            NSString *formatted = [NSString stringWithFormat:QBLocalized(formatKey), sampleName];
            if (![formatted containsString:sampleName] || [formatted containsString:@"%@"])
                [errors addObject:[NSString stringWithFormat:@"Application-name interpolation mismatch: %@", language]];
        }
        NSString *reverseKey = @"Системный фильтр недоступен. Значки оставлены видимыми.";
        QBSetLanguageOverride(@"en");
        NSString *earlierMessage = QBLocalized(reverseKey);
        QBSetLanguageOverride(@"es");
        if (![QBLocalized(earlierMessage) isEqual:catalogs[@"es"][reverseKey]])
            [errors addObject:@"Exact translated-message lookup mismatch"];
    } @finally {
        QBSetLanguageOverride(previousOverride);
    }
    id currentPreference = [NSUserDefaults.standardUserDefaults objectForKey:QBLanguagePreferenceKey];
    if (!(previousPreference == currentPreference || [previousPreference isEqual:currentPreference]))
        [errors addObject:@"Saved language changed during self-test"];
    return @{@"ok":@(errors.count == 0), @"errors":errors, @"languages":QBSupportedLanguages(),
        @"keyCount":@(expected.count), @"resources":resources,
        @"preferredLanguage":QBPreferredLanguage(), @"currentLanguage":QBCurrentLanguage()};
}
