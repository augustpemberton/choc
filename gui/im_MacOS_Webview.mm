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

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
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

    return [[[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] autorelease];
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    NSArray *filePaths = [[sender draggingPasteboard] propertyListForType:NSFilenamesPboardType];
    NSString *jsonString = [self jsonStringForFilePaths:filePaths];
    NSString *jsCode = [NSString stringWithFormat:@"window.ui.handleDragEnter(%@)", jsonString];
    [self evaluateJavaScript:jsCode completionHandler:nil];

    return [super draggingEntered:sender];
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
    NSString *jsCode = @"window.ui.handleDragLeave()";
    [self evaluateJavaScript:jsCode completionHandler:nil];

    return [super draggingExited:sender];
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    NSArray *filePaths = [[sender draggingPasteboard] propertyListForType:NSFilenamesPboardType];
    NSString *jsonString = [self jsonStringForFilePaths:filePaths];
    NSString *jsCode = [NSString stringWithFormat:@"window.ui.handleDragOver(%@)", jsonString];
    [self evaluateJavaScript:jsCode completionHandler:nil];

    return [super draggingUpdated:sender];
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSArray *filePaths = [[sender draggingPasteboard] propertyListForType:NSFilenamesPboardType];
    NSString *jsonString = [self jsonStringForFilePaths:filePaths];
    NSString *jsCode = [NSString stringWithFormat:@"window.ui.handleDragDrop(%@)", jsonString];
    [self evaluateJavaScript:jsCode completionHandler:nil];

    return [super performDragOperation:sender];
}

- (void)keyDown:(NSEvent *)event {
    // letting ESC pass through to Ableton on an AU seems to crash Ableton.
    // my hunch is that it comes from here: https://github.com/juce-framework/JUCE/blob/46c2a95905abffe41a7aa002c70fb30bd3b626ef/modules/juce_audio_plugin_client/juce_audio_plugin_client_AU_1.mm#L1718
    // because that code might call makeFirstResponder on a deleted view, as the host would've just deleted the view becasue of the ESC
    // but in theory this would break on all other plugins, so idk why its just for webview
    if (event.keyCode == 53) {
        NSString *jsCode = @"window.ui.onEscapeKeyDown()";
        [self evaluateJavaScript:jsCode completionHandler:nil];
        return;
    }

    if (acceptKeyEvents) {
        [super keyDown:event];
    } else {
        [[self nextResponder] keyDown:event];
    }
}

- (void)keyUp:(NSEvent *)event {
    if (event.keyCode == 53) {
        NSString *jsCode = @"window.ui.onEscapeKeyUp()";
        [self evaluateJavaScript:jsCode completionHandler:nil];
        return;
    }

    if (acceptKeyEvents) {
        [super keyUp:event];
    } else {
        [[self nextResponder] keyUp:event];
    }
}

- (void)interpretKeyEvents:(NSArray<NSEvent*> *)events {
    [super interpretKeyEvents:events];
}

- (BOOL)performKeyEquivalent:(NSEvent *)event
{

    NSString *characters = [[event charactersIgnoringModifiers] lowercaseString];
    NSEventModifierFlags modifiers = [event modifierFlags];

    if (!acceptKeyEvents) {
        return NO;
    }

    if ([characters isEqualToString:@"c"] && (modifiers & NSEventModifierFlagCommand))
    {
        // Handle copy action
        [self copy:self];
        return YES;
    }
    else if ([characters isEqualToString:@"v"] && (modifiers & NSEventModifierFlagCommand))
    {
        // Handle paste action
        [self paste:self];
        return YES;
    }
    else if ([characters isEqualToString:@"a"] && (modifiers & NSEventModifierFlagCommand))
    {
        // Handle select all action
        [self selectAll:self];
        return YES;
    }
    else if ([characters isEqualToString:@"z"] && (modifiers & NSEventModifierFlagCommand))
    {
        if (modifiers & NSEventModifierFlagShift)
        {
            // Handle redo action
            [self evaluateJavaScript:@"document.execCommand('redo')" completionHandler:nil];
            return YES;
        }
        else
        {
            // Handle undo action
            [self evaluateJavaScript:@"document.execCommand('undo')" completionHandler:nil];
            return YES;
        }
        return YES;
    }

    return [super performKeyEquivalent:event];
}

@end

namespace choc::ui {

    id WebView::Pimpl::allocateWebview()
    {
        static WebviewClass c;
        return objc::call<id> ((id)objc_getClass("imagiroWebView"), "alloc");
    }

    WebView::Pimpl::WebviewClass::WebviewClass()
    {
        webviewClass = choc::objc::createDelegateClass ("imagiroWebView", "CHOCWebView_");

        objc_registerClassPair (webviewClass);
    }


    void WebView::Pimpl::onResourceRequested(void* taskPtr)
    {
        auto task = (__bridge id<WKURLSchemeTask>)taskPtr;

        @try
        {
            NSURL* requestUrl = task.request.URL;

            auto makeResponse = [&](NSInteger responseCode, NSDictionary* mutableHeaderFields)
            {
                NSHTTPURLResponse* response = [[[NSHTTPURLResponse alloc] initWithURL:requestUrl
                                                                           statusCode:responseCode
                                                                          HTTPVersion:@"HTTP/1.1"
                                                                         headerFields:mutableHeaderFields] autorelease];
                return response;
            };


            NSString* path = requestUrl.path;
            std::string pathStr = path.UTF8String;

            if (auto resource = options->fetchResource(pathStr))
            {
                const auto& [bytes, mimeType] = *resource;

                NSString* contentLength = [NSString stringWithFormat:@"%lu", bytes.size()];
                NSString* mimeTypeNS = [NSString stringWithUTF8String:mimeType.c_str()];
                NSDictionary* headerFields = @{
                        @"Content-Length": contentLength,
                        @"Content-Type": mimeTypeNS,
                        @"Cache-Control": @"no-store",
                        @"Access-Control-Allow-Origin": @"*",
                };

                [task didReceiveResponse:makeResponse(200, headerFields)];

                NSData* data = [NSData dataWithBytes:bytes.data() length:bytes.size()];
                [task didReceiveData:data];
            }
            else
            {
                [task didReceiveResponse:makeResponse(404, nil)];
            }

            [task didFinish];
        }
        @catch (...)
        {
            NSError* error = [NSError errorWithDomain:NSURLErrorDomain code:-1 userInfo:nil];
            [task didFailWithError:error];
        }

    }


};
