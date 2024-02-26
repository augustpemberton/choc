#import "im_MacOS_Webview.h"
#include "choc_WebView.h"
#include "choc_MessageLoop.h"

@implementation imagiroWebView

- (instancetype)initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration {
    self = [super initWithFrame:frame configuration:configuration];
    if (self) {
        [self registerForDraggedTypes:@[NSFilenamesPboardType]];
        acceptKeyEvents = NO;
    }
    return self;
}

- (void)setAcceptKeyEvents:(BOOL)accept {
    acceptKeyEvents = accept;
}

- (NSString *)jsonStringForFilePaths:(NSArray *)filePaths {
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:filePaths
                                                       options:0
                                                         error:&error];
    if (!jsonData) {
        NSLog(@"Failed to serialize file paths to JSON: %@", error);
        return @"[]"; // Return an empty array representation in case of error
    }

    return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    NSArray *filePaths = [[sender draggingPasteboard] propertyListForType:NSFilenamesPboardType];
    NSString *jsonString = [self jsonStringForFilePaths:filePaths];
    NSString *jsCode = [NSString stringWithFormat:@"window.ui.handleDragEnter(%@)", jsonString];
    [self evaluateJavaScript:jsCode completionHandler:nil];
    return NSDragOperationCopy;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
    NSString *jsCode = @"window.ui.handleDragLeave()";
    [self evaluateJavaScript:jsCode completionHandler:nil];
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    NSArray *filePaths = [[sender draggingPasteboard] propertyListForType:NSFilenamesPboardType];
    NSString *jsonString = [self jsonStringForFilePaths:filePaths];
    NSString *jsCode = [NSString stringWithFormat:@"window.ui.handleDragOver(%@)", jsonString];
    [self evaluateJavaScript:jsCode completionHandler:nil];
    return NSDragOperationCopy;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSArray *filePaths = [[sender draggingPasteboard] propertyListForType:NSFilenamesPboardType];
    NSString *jsonString = [self jsonStringForFilePaths:filePaths];
    NSString *jsCode = [NSString stringWithFormat:@"window.ui.handleDragDrop(%@)", jsonString];
    [self evaluateJavaScript:jsCode completionHandler:nil];
    return YES;
}

- (void)keyDown:(NSEvent *)event {
    if (acceptKeyEvents) {
        [super keyDown:event];
    } else {
        [[self nextResponder] keyDown:event];
    }
}

- (void)keyUp:(NSEvent *)event {
    if (acceptKeyEvents) {
        [super keyUp:event];
    } else {
        [[self nextResponder] keyUp:event];
    }
}

- (void)interpretKeyEvents:(NSArray<NSEvent*> *)events {
    [super interpretKeyEvents:events];
}

@end

namespace choc::ui {

    WebView::Pimpl::Pimpl (WebView& v, const Options& optionsToUse)
            : owner (v), options (std::make_unique<Options> (optionsToUse))
    {
        using namespace choc::objc;
        CHOC_AUTORELEASE_BEGIN

            defaultURI = getURIHome (*options);

            id config = callClass<id> ("WKWebViewConfiguration", "new");

            id prefs = call<id> (config, "preferences");
            call<void> (prefs, "setValue:forKey:", getNSNumberBool (true), getNSString ("fullScreenEnabled"));
            call<void> (prefs, "setValue:forKey:", getNSNumberBool (true), getNSString ("DOMPasteAllowed"));
            call<void> (prefs, "setValue:forKey:", getNSNumberBool (true), getNSString ("javaScriptCanAccessClipboard"));

            if (options->enableDebugMode)
                call<void> (prefs, "setValue:forKey:", getNSNumberBool (true), getNSString ("developerExtrasEnabled"));

            delegate = createDelegate();
            objc_setAssociatedObject (delegate, "choc_webview", (CHOC_OBJC_CAST_BRIDGED id) this, OBJC_ASSOCIATION_ASSIGN);

            manager = call<id> (config, "userContentController");
            call<void> (manager, "retain");
            call<void> (manager, "addScriptMessageHandler:name:", delegate, getNSString ("external"));

            if (options->fetchResource)
                call<void> (config, "setURLSchemeHandler:forURLScheme:", delegate, getNSString (getURIScheme (*options)));

            webview = call<id> (allocateWebview(), "initWithFrame:configuration:", objc::CGRect(), config);
            objc_setAssociatedObject (webview, "choc_webview", (CHOC_OBJC_CAST_BRIDGED id) this, OBJC_ASSOCIATION_ASSIGN);

            if (! options->customUserAgent.empty())
                call<void> (webview, "setValue:forKey:", getNSString (options->customUserAgent), getNSString ("customUserAgent"));

            call<void> (webview, "setUIDelegate:", delegate);
            call<void> (webview, "setNavigationDelegate:", delegate);

            if (options->transparentBackground)
                call<void> (webview, "setValue:forKey:", getNSNumberBool (false), getNSString ("drawsBackground"));

            call<void> (config, "release");

            if (options->fetchResource)
                navigate ({});

            owner.bind("juce_enableKeyEvents", [&](const choc::value::ValueView &args) -> choc::value::Value {
                call<void>(webview, "setAcceptKeyEvents:", args[0].getWithDefault(false));
                return {};
            });

        CHOC_AUTORELEASE_END

    }

    WebView::Pimpl::~Pimpl()
    {
        CHOC_AUTORELEASE_BEGIN
            deletionChecker->deleted = true;
            objc_setAssociatedObject (delegate, "choc_webview", nil, OBJC_ASSOCIATION_ASSIGN);
            objc_setAssociatedObject (webview, "choc_webview", nil, OBJC_ASSOCIATION_ASSIGN);
            objc::call<void> (webview, "release");
            webview = {};
            objc::call<void> (manager, "removeScriptMessageHandlerForName:", objc::getNSString ("external"));
            objc::call<void> (manager, "release");
            manager = {};
            objc::call<void> (delegate, "release");
            delegate = {};
        CHOC_AUTORELEASE_END
    }

    bool WebView::Pimpl::evaluateJavascript (const std::string& script, CompletionHandler completionHandler)
    {
        CHOC_AUTORELEASE_BEGIN
            auto s = objc::getNSString (script);

            if (completionHandler) {
                objc::call<void>(webview, "evaluateJavaScript:completionHandler:", s,
                                 ^(id result, id error) {
                                     CHOC_AUTORELEASE_BEGIN

                                         auto errorMessage = getMessageFromNSError(error);
                                         choc::value::Value value;

                                         try {
                                             if (auto json = convertNSObjectToJSON(result); !json.empty())
                                                 value = choc::json::parseValue(json);
                                         }
                                         catch (const std::exception &e) {
                                             errorMessage = e.what();
                                         }

                                         completionHandler(errorMessage, value);
                                     CHOC_AUTORELEASE_END
                                 });
            } else {
                objc::call<void> (webview, "evaluateJavaScript:completionHandler:", s, (id) nullptr);
            }
            return true;
        CHOC_AUTORELEASE_END
    }

    id WebView::Pimpl::allocateWebview()
    {
        static WebviewClass c;
        return objc::call<id> ((id)objc_getClass("imagiroWebView"), "alloc");
    }

    WebView::Pimpl::WebviewClass::WebviewClass()
    {
        webviewClass = choc::objc::createDelegateClass ("imagiroWebView", "CHOCWebView_");

        class_addMethod (webviewClass, sel_registerName ("acceptsFirstMouse:"),
                         (IMP) (+[](id self, SEL, id) -> BOOL
                         {
                             if (auto p = getPimpl (self))
                                 return p->options->acceptsFirstMouseClick;

                             return false;
                         }), "B@:@");

        class_addMethod (webviewClass, sel_registerName ("performKeyEquivalent:"),
                         (IMP) (+[](id self, SEL, id e) -> BOOL
                         {
                             if (auto p = getPimpl (self))
                                 if (p->performKeyEquivalent (self, e))
                                     return true;

                             return choc::objc::callSuper<BOOL> (self, "performKeyEquivalent:", e);
                         }), "B@:@");

        objc_registerClassPair (webviewClass);
    }

    WebView::Pimpl::WebviewClass::~WebviewClass()
    {
        // NB: it doesn't seem possible to dispose of this class late enough to avoid a warning on shutdown
        // about the KVO system still using it, so unfortunately the only option seems to be to let it leak..
        // objc_disposeClassPair (webviewClass);
    }

    Class webviewClass = {};

};
