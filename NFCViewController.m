#include <stdint.h>
#include <stdlib.h>
#import "NFCViewController.h"

// NFC PRANK v1.0 - by thxrealx7
// Only password protection (reversible): never set permanent lock bits or CFGLCK.

typedef NS_ENUM(NSUInteger, NPAction) {
    NPActionRead,
    NPActionWrite,
    NPActionErase,
    NPActionLock,
    NPActionUnlock,
};

typedef void (^NPResult)(NSData *data, NSError *error);

typedef struct {
    uint8_t cfg0;
    uint8_t cfg1;
    uint8_t pwd;
    uint8_t pack;
    uint8_t lastUserPage;
} NPLayout;

static BOOL NPLayoutForVersion(NSData *response, NPLayout *result) {
    if (response.length != 8) return NO;
    const uint8_t *b = response.bytes;
    if (b[0] != 0 || b[1] != 4 || b[2] != 4 || b[3] != 2 || b[7] != 3) return NO;
    switch (b[6]) {
        case 0x0F: *result = (NPLayout){0x29, 0x2A, 0x2B, 0x2C, 0x27}; return YES;
        case 0x11: *result = (NPLayout){0x83, 0x84, 0x85, 0x86, 0x81}; return YES;
        case 0x13: *result = (NPLayout){0xE3, 0xE4, 0xE5, 0xE6, 0xE1}; return YES;
        default: return NO;
    }
}

static NSError *NPError(NSString *description) {
    return [NSError errorWithDomain:@"NFCPrank" code:1 userInfo:@{NSLocalizedDescriptionKey:description ?: @"Неизвестная ошибка"}];
}

static BOOL NPParsePassword(NSString *input, uint8_t output[4]) {
    NSString *s = [[input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] uppercaseString];
    if (s.length != 8) return NO;
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEF"];
    for (NSUInteger i = 0; i < 8; i++) if (![hex characterIsMember:[s characterAtIndex:i]]) return NO;
    for (NSUInteger i = 0; i < 4; i++) {
        NSString *part = [s substringWithRange:NSMakeRange(i * 2, 2)];
        unsigned value = 0;
        [[NSScanner scannerWithString:part] scanHexInt:&value];
        output[i] = (uint8_t)value;
    }
    return YES;
}

static NSString *NPHexString(NSData *data) {
    NSMutableString *s = [NSMutableString string];
    const uint8_t *b = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) [s appendFormat:@"%02X", b[i]];
    return s;
}

@interface NFCViewController ()
@property (nonatomic, strong) UITextView *payloadView;
@property (nonatomic, strong) UITextField *pinView;
@property (nonatomic, strong) UISegmentedControl *kindView;
@property (nonatomic, strong) UILabel *statusView;
@property (nonatomic, strong) UILabel *outputView;
@property (nonatomic, strong) NFCTagReaderSession *session;
@property (nonatomic, assign) NPAction action;
@property (nonatomic, copy) NSString *capturedValue;
@property (nonatomic, copy) NSString *capturedPin;
@property (nonatomic, assign) NSInteger capturedKind;
@property (nonatomic, assign) BOOL completing;
@end

@implementation NFCViewController

- (UIColor *)backgroundColor { return [UIColor colorWithRed:0.055 green:0.065 blue:0.105 alpha:1]; }
- (UIColor *)panelColor { return [UIColor colorWithRed:0.105 green:0.12 blue:0.18 alpha:1]; }
- (UIColor *)purple { return [UIColor colorWithRed:0.58 green:0.34 blue:1 alpha:1]; }

- (UILabel *)label:(NSString *)text size:(CGFloat)size color:(UIColor *)color {
    UILabel *l = [UILabel new];
    l.text = text;
    l.font = [UIFont systemFontOfSize:size weight:UIFontWeightMedium];
    l.textColor = color;
    l.numberOfLines = 0;
    return l;
}

- (UIView *)panelWithContent:(UIStackView *)content {
    UIView *v = [UIView new];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    v.backgroundColor = [self panelColor];
    v.layer.cornerRadius = 20;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:v.topAnchor constant:18],
        [content.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:16],
        [content.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-16],
        [content.bottomAnchor constraintEqualToAnchor:v.bottomAnchor constant:-18]
    ]];
    return v;
}

- (UIStackView *)vertical:(CGFloat)gap {
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = gap;
    stack.alignment = UIStackViewAlignmentFill;
    return stack;
}

- (UIButton *)button:(NSString *)title selector:(SEL)selector color:(UIColor *)color {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    b.backgroundColor = color;
    b.layer.cornerRadius = 13;
    [b addTarget:self action:selector forControlEvents:UIControlEventTouchUpInside];
    [b.heightAnchor constraintEqualToConstant:50].active = YES;
    return b;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [self backgroundColor];
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
    UIStackView *root = [self vertical:18];
    root.translatesAutoresizingMaskIntoConstraints = NO;
    root.layoutMarginsRelativeArrangement = YES;
    root.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(24, 20, 36, 20);
    [scroll addSubview:root];
    [NSLayoutConstraint activateConstraints:@[
        [root.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [root.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [root.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [root.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [root.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor]
    ]];

    UILabel *eyebrow = [self label:@"NFC TOOLKIT • 1.0" size:12 color:[self purple]];
    eyebrow.font = [UIFont systemFontOfSize:12 weight:UIFontWeightHeavy];
    [root addArrangedSubview:eyebrow];
    UILabel *hero = [self label:@"NFC PRANK" size:37 color:UIColor.whiteColor];
    hero.font = [UIFont systemFontOfSize:37 weight:UIFontWeightBlack];
    [root addArrangedSubview:hero];
    UILabel *sub = [self label:@"Читай, записывай, очищай и защищай свои NFC-метки." size:15 color:UIColor.lightGrayColor];
    [root addArrangedSubview:sub];

    UIStackView *writePanel = [self vertical:12];
    [writePanel addArrangedSubview:[self label:@"ЗАПИСЬ NDEF" size:13 color:UIColor.lightGrayColor]];
    self.kindView = [[UISegmentedControl alloc] initWithItems:@[@"Текст", @"Ссылка"]];
    self.kindView.selectedSegmentIndex = 0;
    [self.kindView addTarget:self action:@selector(changeKind) forControlEvents:UIControlEventValueChanged];
    [writePanel addArrangedSubview:self.kindView];
    self.payloadView = [UITextView new];
    self.payloadView.text = @"created by thxrealx7";
    self.payloadView.font = [UIFont systemFontOfSize:17];
    self.payloadView.textColor = UIColor.whiteColor;
    self.payloadView.backgroundColor = [self backgroundColor];
    self.payloadView.layer.cornerRadius = 12;
    self.payloadView.textContainerInset = UIEdgeInsetsMake(12, 10, 12, 10);
    [self.payloadView.heightAnchor constraintEqualToConstant:108].active = YES;
    [writePanel addArrangedSubview:self.payloadView];
    [writePanel addArrangedSubview:[self button:@"Записать на метку" selector:@selector(writePressed) color:[self purple]]];
    [root addArrangedSubview:[self panelWithContent:writePanel]];

    UIStackView *managePanel = [self vertical:12];
    [managePanel addArrangedSubview:[self label:@"МЕТКА" size:13 color:UIColor.lightGrayColor]];
    [managePanel addArrangedSubview:[self button:@"Считать содержимое" selector:@selector(readPressed) color:[UIColor colorWithRed:.19 green:.35 blue:.45 alpha:1]]];
    [managePanel addArrangedSubview:[self button:@"Полностью очистить NDEF-память" selector:@selector(erasePressed) color:[UIColor colorWithRed:.55 green:.25 blue:.30 alpha:1]]];
    [root addArrangedSubview:[self panelWithContent:managePanel]];

    UIStackView *lockPanel = [self vertical:12];
    [lockPanel addArrangedSubview:[self label:@"СНИМАЕМАЯ ЗАЩИТА • NTAG213 / 215 / 216" size:13 color:UIColor.lightGrayColor]];
    [lockPanel addArrangedSubview:[self label:@"Пароль: ровно 8 HEX-символов. Сохрани его! Без него защита может остаться навсегда." size:13 color:UIColor.lightGrayColor]];
    self.pinView = [UITextField new];
    self.pinView.placeholder = @"Например: 1A2B3C4D";
    self.pinView.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    self.pinView.autocorrectionType = UITextAutocorrectionTypeNo;
    self.pinView.textColor = UIColor.whiteColor;
    self.pinView.backgroundColor = [self backgroundColor];
    self.pinView.layer.cornerRadius = 12;
    self.pinView.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 1)];
    self.pinView.leftViewMode = UITextFieldViewModeAlways;
    [self.pinView.heightAnchor constraintEqualToConstant:48].active = YES;
    [lockPanel addArrangedSubview:self.pinView];
    UIStackView *pinButtons = [[UIStackView alloc] init];
    pinButtons.axis = UILayoutConstraintAxisHorizontal;
    pinButtons.spacing = 10;
    pinButtons.distribution = UIStackViewDistributionFillEqually;
    [pinButtons addArrangedSubview:[self button:@"Создать пароль" selector:@selector(generatePin) color:[UIColor colorWithRed:.24 green:.26 blue:.36 alpha:1]]];
    [pinButtons addArrangedSubview:[self button:@"Копировать" selector:@selector(copyPin) color:[UIColor colorWithRed:.24 green:.26 blue:.36 alpha:1]]];
    [lockPanel addArrangedSubview:pinButtons];
    [lockPanel addArrangedSubview:[self button:@"Заблокировать чтение и запись" selector:@selector(lockPressed) color:[self purple]]];
    [lockPanel addArrangedSubview:[self button:@"Снять блокировку" selector:@selector(unlockPressed) color:[UIColor colorWithRed:.13 green:.48 blue:.37 alpha:1]]];
    [lockPanel addArrangedSubview:[self label:@"Не блокирует UID, транспортные карты, банковские карты и метки других типов. Постоянный hardware-lock отключён." size:12 color:UIColor.lightGrayColor]];
    [root addArrangedSubview:[self panelWithContent:lockPanel]];

    UIStackView *resultPanel = [self vertical:8];
    self.statusView = [self label:@"Готово к сканированию" size:16 color:UIColor.whiteColor];
    self.outputView = [self label:@"Приложи NFC-метку к верхней части iPhone после нажатия кнопки." size:13 color:UIColor.lightGrayColor];
    [resultPanel addArrangedSubview:self.statusView];
    [resultPanel addArrangedSubview:self.outputView];
    [root addArrangedSubview:[self panelWithContent:resultPanel]];
    UILabel *credit = [self label:@"created by thxrealx7" size:12 color:UIColor.grayColor];
    credit.textAlignment = NSTextAlignmentCenter;
    [root addArrangedSubview:credit];
}

- (void)changeKind {
    self.payloadView.text = self.kindView.selectedSegmentIndex == 0 ? @"created by thxrealx7" : @"https://example.com";
}

- (void)generatePin {
    uint8_t b[4] = {0};
    arc4random_buf(b, sizeof(b));
    self.pinView.text = [NSString stringWithFormat:@"%02X%02X%02X%02X", b[0], b[1], b[2], b[3]];
}
- (void)copyPin {
    uint8_t b[4];
    if (!NPParsePassword(self.pinView.text, b)) { [self showError:@"Сначала создай или введи пароль из 8 HEX-символов."]; return; }
    UIPasteboard.generalPasteboard.string = self.pinView.text.uppercaseString;
    [self updateStatus:@"Пароль скопирован" detail:@"Сохрани пароль отдельно. Буфер обмена не является защищённым хранилищем."];
}

- (void)showError:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"NFC PRANK" message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Понятно" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}
- (void)updateStatus:(NSString *)title detail:(NSString *)detail {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusView.text = title;
        self.outputView.text = detail;
    });
}
- (BOOL)pinRequired {
    uint8_t b[4];
    if (!NPParsePassword(self.pinView.text, b)) {
        [self showError:@"Для блокировки и разблокировки нужен пароль из 8 HEX-символов (0-9, A-F)."];
        return NO;
    }
    return YES;
}
- (void)readPressed { [self begin:NPActionRead]; }
- (void)writePressed {
    NSString *text = [self.payloadView.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length) { [self showError:@"Введи текст или ссылку."]; return; }
    if (self.kindView.selectedSegmentIndex == 1) {
        NSURL *url = [NSURL URLWithString:text];
        NSString *scheme = url.scheme.lowercaseString;
        if (!url.host.length || !([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"])) {
            [self showError:@"Укажи полную ссылку, начинающуюся с https:// или http://."];
            return;
        }
    }
    [self begin:NPActionWrite];
}
- (void)erasePressed {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Очистить память метки?"
        message:@"Будет перезаписана ВСЯ пользовательская память NTAG213/215/216, а не только видимая запись. Это нельзя отменить. Не убирай iPhone до завершения."
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Отмена" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Очистить мою метку" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) { (void)action; [self begin:NPActionErase]; }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)lockPressed {
    if (![self pinRequired]) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Защитить NFC-метку?"
        message:@"Только NTAG213/215/216. Чтение и запись пользовательской области будут закрыты 4-байтовым паролем. Если потеряешь пароль, разблокировка может стать невозможной. Приложение не включает необратимую аппаратную блокировку."
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Отмена" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Защитить мою метку" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { (void)action; [self begin:NPActionLock]; }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)unlockPressed { if ([self pinRequired]) [self begin:NPActionUnlock]; }

- (void)begin:(NPAction)action {
    if (![NFCTagReaderSession readingAvailable]) {
        [self showError:@"Core NFC недоступен на этом устройстве или в этой сборке iOS."];
        return;
    }
    if (self.session) { [self showError:@"Уже идёт сканирование."]; return; }
    [self.view endEditing:YES];
    self.action = action;
    self.capturedValue = [[self.payloadView.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] copy];
    self.capturedPin = [self.pinView.text copy] ?: @"";
    self.capturedKind = self.kindView.selectedSegmentIndex;
    self.completing = NO;
    NFCPollingOption opts = NFCPollingISO14443 | NFCPollingISO15693 | NFCPollingISO18092;
    self.session = [[NFCTagReaderSession alloc] initWithPollingOption:opts delegate:self queue:nil];
    self.session.alertMessage = @"Приложи свою NFC-метку к верхней части iPhone и держи до завершения.";
    [self updateStatus:@"Поиск NFC-метки…" detail:@"Не убирай метку от телефона."];
    [self.session beginSession];
}

- (void)finish:(NSString *)title detail:(NSString *)detail error:(NSError *)error {
    @synchronized (self) {
        if (self.completing) return;
        self.completing = YES;
    }
    if (error) {
        [self updateStatus:@"Ошибка операции" detail:error.localizedDescription];
        [self.session invalidateSessionWithErrorMessage:error.localizedDescription];
    } else {
        [self updateStatus:title detail:detail];
        self.session.alertMessage = title;
        [self.session invalidateSession];
    }
    self.session = nil;
}

- (void)tagReaderSessionDidBecomeActive:(NFCTagReaderSession *)session { (void)session; }
- (void)tagReaderSession:(NFCTagReaderSession *)session didInvalidateWithError:(NSError *)error {
    if (session != self.session) return;
    self.session = nil;
    if (!self.completing && error.code != 200) {
        [self updateStatus:@"Сканирование завершилось" detail:error.localizedDescription];
    } else if (!self.completing) {
        [self updateStatus:@"Отменено" detail:@"Снова нажми нужную кнопку для сканирования."];
    }
}
- (void)tagReaderSession:(NFCTagReaderSession *)session didDetectTags:(NSArray<__kindof id<NFCTag>> *)tags {
    if (tags.count != 1) {
        session.alertMessage = @"В поле несколько меток. Оставь одну.";
        [session restartPolling];
        return;
    }
    id<NFCTag> tag = tags.firstObject;
    [session connectToTag:tag completionHandler:^(NSError *error) {
        if (error) { [self finish:nil detail:nil error:error]; return; }
        if (self.action == NPActionRead || self.action == NPActionWrite) {
            [self runNDEFOnTag:tag];
        } else {
            id<NFCMiFareTag> mifare = [tag asNFCMiFareTag];
            if (!mifare) { [self finish:nil detail:nil error:NPError(@"Для этой операции нужна NTAG213, NTAG215 или NTAG216.")]; return; }
            [self runRawOnTag:mifare];
        }
    }];
}

- (void)send:(NSData *)packet to:(id<NFCMiFareTag>)tag completion:(NPResult)completion {
    [tag sendMiFareCommand:packet completionHandler:^(NSData *response, NSError *error) {
        completion(response, error);
    }];
}
- (void)readPage:(uint8_t)page tag:(id<NFCMiFareTag>)tag completion:(NPResult)completion {
    uint8_t packet[] = {0x30, page};
    [self send:[NSData dataWithBytes:packet length:2] to:tag completion:completion];
}
- (void)writePage:(uint8_t)page data:(const uint8_t[4])bytes tag:(id<NFCMiFareTag>)tag completion:(NPResult)completion {
    uint8_t packet[] = {0xA2, page, bytes[0], bytes[1], bytes[2], bytes[3]};
    [self send:[NSData dataWithBytes:packet length:6] to:tag completion:completion];
}
- (void)withLayout:(id<NFCMiFareTag>)tag completion:(void (^)(NPLayout layout, NSError *error))done {
    uint8_t cmd = 0x60;
    [self send:[NSData dataWithBytes:&cmd length:1] to:tag completion:^(NSData *resp, NSError *error) {
        NPLayout layout = {0};
        if (error || !NPLayoutForVersion(resp, &layout)) {
            done(layout, NPError(@"Не удалось точно определить NTAG213/215/216. Память не изменена."));
            return;
        }
        done(layout, nil);
    }];
}
- (void)authenticate:(id<NFCMiFareTag>)tag completion:(void (^)(BOOL valid, NSError *error))done {
    uint8_t pin[4];
    if (!NPParsePassword(self.capturedPin, pin)) { done(NO, NPError(@"Введи правильный пароль (8 HEX-символов).")); return; }
    uint8_t cmd[] = {0x1B, pin[0], pin[1], pin[2], pin[3]};
    [self send:[NSData dataWithBytes:cmd length:5] to:tag completion:^(NSData *response, NSError *error) {
        if (error || response.length < 2) { done(NO, NPError(@"Пароль не подошёл или метка не поддерживает авторизацию.")); return; }
        if (self.action == NPActionUnlock) {
            const uint8_t *pack = response.bytes;
            if (pack[0] != 0x58 || pack[1] != 0x37) {
                done(NO, NPError(@"Это не блокировка NFC PRANK (неизвестный PACK). Конфигурация оставлена без изменений."));
                return;
            }
        }
        done(YES, nil);
    }];
}
- (void)authenticateIfProvided:(id<NFCTag>)tag completion:(void (^)(NSError *error))done {
    NSString *pin = [self.capturedPin stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!pin.length) { done(nil); return; }
    id<NFCMiFareTag> m = [tag asNFCMiFareTag];
    if (!m) { done(NPError(@"Пароль доступен только для совместимых NTAG-меток.")); return; }
    [self authenticate:m completion:^(BOOL valid, NSError *error) { (void)valid; done(error); }];
}

- (void)runNDEFOnTag:(id<NFCTag>)tag {
    id<NFCNDEFTag> ndef = (id<NFCNDEFTag>)tag;
    [self authenticateIfProvided:tag completion:^(NSError *authError) {
        if (authError) { [self finish:nil detail:nil error:authError]; return; }
        [ndef queryNDEFStatusWithCompletionHandler:^(NFCNDEFStatus status, NSUInteger capacity, NSError *error) {
            if (error) { [self finish:nil detail:nil error:error]; return; }
            if (status == NFCNDEFStatusNotSupported) {
                [self finish:nil detail:nil error:NPError(@"На этой метке нет поддерживаемой структуры NDEF.")]; return;
            }
            if (self.action == NPActionRead) {
                [ndef readNDEFWithCompletionHandler:^(NFCNDEFMessage *message, NSError *readError) {
                    if (readError) { [self finish:nil detail:nil error:readError]; return; }
                    NSMutableArray<NSString *> *records = [NSMutableArray array];
                    for (NFCNDEFPayload *p in message.records) {
                        NSLocale *__autoreleasing recordLocale = nil;
                        NSString *value = [p wellKnownTypeTextPayloadWithLocale:&recordLocale];
                        if (!value) value = [[p wellKnownTypeURIPayload] absoluteString];
                        if (!value) value = [NSString stringWithFormat:@"Данные: %@", NPHexString(p.payload)];
                        [records addObject:value];
                    }
                    NSString *uid = @"";
                    id<NFCMiFareTag> m = [tag asNFCMiFareTag];
                    if (m) uid = [NSString stringWithFormat:@"UID: %@\n", NPHexString(m.identifier)];
                    [self finish:@"Метка прочитана" detail:[NSString stringWithFormat:@"%@Свободная ёмкость: %lu байт\n%@", uid, (unsigned long)capacity, records.count ? [records componentsJoinedByString:@"\n"] : @"Записей нет"] error:nil];
                }];
                return;
            }
            if (status != NFCNDEFStatusReadWrite) {
                [self finish:nil detail:nil error:NPError(@"Метка доступна только для чтения. Сними защиту, если она установлена через NFC PRANK.")]; return;
            }
            NFCNDEFPayload *p = nil;
            if (self.capturedKind == 1) {
                p = [NFCNDEFPayload wellKnownTypeURIPayloadWithURL:[NSURL URLWithString:self.capturedValue]];
            } else {
                p = [NFCNDEFPayload wellKnownTypeTextPayloadWithString:self.capturedValue locale:[NSLocale localeWithLocaleIdentifier:@"ru_RU"]];
            }
            if (!p) { [self finish:nil detail:nil error:NPError(@"Не удалось сформировать NDEF-запись.")]; return; }
            NFCNDEFMessage *message = [[NFCNDEFMessage alloc] initWithNDEFRecords:@[p]];
            if (message.length > capacity) { [self finish:nil detail:nil error:NPError(@"Текст или ссылка не помещаются в память метки.")]; return; }
            [ndef writeNDEF:message completionHandler:^(NSError *writeError) {
                [self finish:@"Успешно записано" detail:self.capturedValue error:writeError];
            }];
        }];
    }];
}

- (void)runRawOnTag:(id<NFCMiFareTag>)tag {
    [self withLayout:tag completion:^(NPLayout layout, NSError *error) {
        if (error) { [self finish:nil detail:nil error:error]; return; }
        switch (self.action) {
            case NPActionErase: [self eraseTag:tag layout:layout]; break;
            case NPActionLock: [self lockTag:tag layout:layout]; break;
            case NPActionUnlock: [self unlockTag:tag layout:layout]; break;
            default: break;
        }
    }];
}

// Wipe only user data pages 04h ... lastUserPage. Do not touch UID, CC,
// static/dynamic lock bytes, configuration, PWD/PACK, or manufacturer data.
// Page 04 is written last, leaving a valid empty NDEF TLV (03 00 FE 00).
- (void)eraseTag:(id<NFCMiFareTag>)tag layout:(NPLayout)layout {
    [self authenticateIfProvided:(id<NFCTag>)tag completion:^(NSError *authError) {
        if (authError) { [self finish:nil detail:nil error:authError]; return; }
        [self erasePage:5 last:layout.lastUserPage tag:tag];
    }];
}
- (void)erasePage:(NSUInteger)page last:(NSUInteger)last tag:(id<NFCMiFareTag>)tag {
    if (page > last) {
        const uint8_t empty[4] = {0x03, 0x00, 0xFE, 0x00};
        [self writePage:4 data:empty tag:tag completion:^(NSData *data, NSError *error) {
            (void)data;
            [self finish:@"Пользовательская память очищена" detail:@"NDEF пустой. UID и служебные области сохранены." error:error];
        }];
        return;
    }
    if (page % 12 == 0) [self updateStatus:@"Очистка NFC…" detail:[NSString stringWithFormat:@"Страница %lu из %lu. Держи метку у телефона.", (unsigned long)page, (unsigned long)last]];
    const uint8_t zero[4] = {0, 0, 0, 0};
    [self writePage:(uint8_t)page data:zero tag:tag completion:^(NSData *response, NSError *error) {
        (void)response;
        if (error) { [self finish:nil detail:nil error:NPError([NSString stringWithFormat:@"Очистка прервалась на странице %lu. Часть данных могла остаться: %@", (unsigned long)page, error.localizedDescription])]; return; }
        [self erasePage:page + 1 last:last tag:tag];
    }];
}

// Generic read of the 4 configuration pages; PWD and PACK read as zero by design.
- (void)readConfig:(id<NFCMiFareTag>)tag layout:(NPLayout)layout completion:(NPResult)done {
    [self readPage:layout.cfg0 tag:tag completion:^(NSData *data, NSError *error) {
        if (error || data.length < 8) { done(nil, error ?: NPError(@"Не удалось получить конфигурацию NTAG.")); return; }
        done(data, nil);
    }];
}

- (void)lockTag:(id<NFCMiFareTag>)tag layout:(NPLayout)layout {
    [self readConfig:tag layout:layout completion:^(NSData *conf, NSError *error) {
        if (error) { [self finish:nil detail:nil error:error]; return; }
        const uint8_t *b = conf.bytes;
        if (b[3] != 0xFF) {
            [self finish:nil detail:nil error:NPError(@"Защита уже настроена. Во избежание потери доступа чужая конфигурация не перезаписывается.")]; return;
        }
        if ((b[4] & 0x40) != 0 || (b[4] & 0x07) != 0) {
            [self finish:nil detail:nil error:NPError(@"Метка использует заблокированные настройки или лимит PIN-попыток. Операция отменена.")]; return;
        }
        uint8_t password[4];
        if (!NPParsePassword(self.capturedPin, password)) { [self finish:nil detail:nil error:NPError(@"Неверный формат пароля.")]; return; }
        // 1. Write password, 2. write identifier PACK, 3. enable read protection,
        // 4. finally set AUTH0=04 to activate protection. No irreversible bits.
        [self writePage:layout.pwd data:password tag:tag completion:^(NSData *r1, NSError *e1) {
            (void)r1;
            if (e1) { [self finish:nil detail:nil error:e1]; return; }
            const uint8_t pack[4] = {0x58, 0x37, 0x00, 0x00}; // "X7" marker
            [self writePage:layout.pack data:pack tag:tag completion:^(NSData *r2, NSError *e2) {
                (void)r2;
                if (e2) { [self finish:nil detail:nil error:e2]; return; }
                const uint8_t access[4] = {(uint8_t)(b[4] | 0x80), b[5], b[6], b[7]};
                [self writePage:layout.cfg1 data:access tag:tag completion:^(NSData *r3, NSError *e3) {
                    (void)r3;
                    if (e3) { [self finish:nil detail:nil error:e3]; return; }
                    const uint8_t cfg0[4] = {b[0], b[1], b[2], 0x04};
                    [self writePage:layout.cfg0 data:cfg0 tag:tag completion:^(NSData *r4, NSError *e4) {
                        (void)r4;
                        [self finish:@"Защита включена" detail:@"Чтение и запись пользовательских данных закрыты паролем. Не теряй его!" error:e4];
                    }];
                }];
            }];
        }];
    }];
}

- (void)unlockTag:(id<NFCMiFareTag>)tag layout:(NPLayout)layout {
    [self authenticate:tag completion:^(BOOL valid, NSError *authError) {
        if (!valid) { [self finish:nil detail:nil error:authError]; return; }
        // Only unlock locks created by NFC PRANK, proven by its PACK marker.
        [self readConfig:tag layout:layout completion:^(NSData *conf, NSError *readError) {
            if (readError) { [self finish:nil detail:nil error:readError]; return; }
            const uint8_t *b = conf.bytes;
            if (b[3] != 0x04 || !(b[4] & 0x80) || (b[4] & 0x40)) {
                [self finish:nil detail:nil error:NPError(@"Конфигурация не совпадает с NFC PRANK. Не меняем неизвестную защиту.")]; return;
            }
            // Restore open access first; abort if write fails.
            const uint8_t cfg0[4] = {b[0], b[1], b[2], 0xFF};
            [self writePage:layout.cfg0 data:cfg0 tag:tag completion:^(NSData *r1, NSError *e1) {
                (void)r1;
                if (e1) { [self finish:nil detail:nil error:e1]; return; }
                const uint8_t access[4] = {(uint8_t)(b[4] & 0x7F), b[5], b[6], b[7]};
                [self writePage:layout.cfg1 data:access tag:tag completion:^(NSData *r2, NSError *e2) {
                    (void)r2;
                    [self finish:@"Защита снята" detail:@"Чтение и запись вновь доступны. Можно записывать новые данные." error:e2];
                }];
            }];
        }];
    }];
}
@end
