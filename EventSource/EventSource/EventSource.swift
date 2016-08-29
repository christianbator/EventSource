//
//  EventSource.swift
//  EventSource
//
//  Created by Christian Bator on 8/2/16.
//  Copyright © 2016 FarmLogs. All rights reserved.
//

import Foundation

public enum EventSourceState: String {
    case Open
    case Closed
}

public class EventSource: NSObject {
    
    private var url: NSURL
    private var currentTask: NSURLSessionDataTask?
    private var session: NSURLSession?
    private var userDidClose: Bool = false
    private var didOpen: Bool = false
    
    private var openHandler: EventHandler?
    private var messageHandler: EventHandler?
    private var closeHandler: EventHandler?
    private var errorHandler: EventHandler?
    
    private var handlers: [String : [EventHandler]] = [:]
    
    private var timeoutInterval: NSTimeInterval = DBL_MAX
    private var retryInterval: NSTimeInterval = 3
    private var retryTimer: NSTimer?
    private var lastEventID: String?
    
    public init(url: NSURL) {
        self.url = url
        super.init()
    }
    
    public func open() {
        userDidClose = false
        didOpen = false
        
        currentTask?.cancel()
        session?.invalidateAndCancel()
        
        let configuration = NSURLSessionConfiguration.defaultSessionConfiguration()
        session = NSURLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        
        let request = NSMutableURLRequest(URL: url, cachePolicy: .ReloadIgnoringLocalCacheData, timeoutInterval: timeoutInterval)
        
        if let lastEventID = self.lastEventID {
            request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID")
        }
        
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        
        currentTask = session?.dataTaskWithRequest(request)
        currentTask?.resume()
    }
    
    public func close() {
        userDidClose = true
        didOpen = false
        
        currentTask?.cancel()
        session?.invalidateAndCancel()
        
        retryTimer?.invalidate()
        retryTimer = nil
        
        handleClose()
    }
    
    public func addHandler(eventName: String, handler: EventHandler) {
        if handlers[eventName] == nil {
            handlers[eventName] = []
        }
        
        handlers[eventName]?.append(handler)
    }
    
    public func onOpen(handler: EventHandler) {
        openHandler = handler
    }
    
    public func onMessage(handler: EventHandler) {
        messageHandler = handler
    }
    
    public func onClose(handler: EventHandler) {
        closeHandler = handler
    }
    
    public func onError(handler: EventHandler) {
        errorHandler = handler
    }
    
}


extension EventSource: NSURLSessionDataDelegate {
    
    public func URLSession(session: NSURLSession, dataTask: NSURLSessionDataTask, didReceiveData data: NSData) {
        if !didOpen {
            handleOpen()
        }
        else {
            handleData(data)
        }
    }
    
    public func URLSession(session: NSURLSession, task: NSURLSessionTask, didCompleteWithError error: NSError?) {
        handleError(error)
    }
    
    public func URLSession(session: NSURLSession, didBecomeInvalidWithError error: NSError?) {
        handleError(error)
    }
    
}


extension EventSource {
    
    private func handleOpen() {
        didOpen = true
        
        retryTimer?.invalidate()
        retryTimer = nil
        
        let event = Event(readyState: .Open)
        
        dispatch_async(dispatch_get_main_queue()) {
            self.openHandler?(event)
        }
    }
    
    private func handleData(data: NSData) {
        guard let eventString = String(data: data, encoding: NSUTF8StringEncoding) else {
            return
        }
        
        guard eventString.hasSuffix(EventSeparatorLFLF) ||
            eventString.hasSuffix(EventSeparatorCRCR) ||
            eventString.hasSuffix(EventSeparatorCRLFCRLF) else {
                return
        }
        
        var ID: String?
        var name: String?
        var data: String?
        
        let trimmedEventString = eventString.stringByTrimmingCharactersInSet(NSCharacterSet.newlineCharacterSet())
        let components = trimmedEventString.componentsSeparatedByString(EventKeyValuePairSeparator) as [NSString]
        
        for component in components {
            guard component.length > 0 else {
                continue
            }
            
            let delimiterIndex = component.rangeOfString(KeyValueDelimiter).location
            if delimiterIndex == NSNotFound || delimiterIndex == (component.length - KeyValueDelimiter.characters.count) {
                continue
            }
            
            let key = component.substringToIndex(delimiterIndex)
            let value = component.substringFromIndex(delimiterIndex + KeyValueDelimiter.characters.count)
            
            if key == EventIDKey {
                ID = value
            }
            else if key == EventNameKey {
                name = value
            }
            else if key == EventDataKey {
                data = value
            }
            else if key == EventRetryKey {
                if let timeIntervalValue = NSTimeInterval(value) {
                    self.retryInterval = timeIntervalValue
                }
            }
        }
        
        self.lastEventID = ID
        
        let event = Event(readyState: .Open, ID: ID, name: name, data: data)
        
        dispatch_async(dispatch_get_main_queue()) {
            self.messageHandler?(event)
        }
        
        if let eventName = event.name,
            let namedEventhandlers = self.handlers[eventName] {
            for handler in namedEventhandlers {
                dispatch_async(dispatch_get_main_queue()) {
                    handler(event)
                }
            }
        }
    }
    
    private func handleClose() {
        didOpen = false
        
        let event = Event(readyState: .Closed)
      
        dispatch_async(dispatch_get_main_queue()) {
            self.closeHandler?(event)
        }
    }
    
    private func handleError(sessionError: NSError?) {
        didOpen = false
        
        if !userDidClose {
            let error = sessionError != nil ? sessionError : NSError(domain: "com.jcbator.eventsource", code: -1, userInfo: ["message" : "Unknown Error"])
            let event = Event(readyState: .Closed, error: error)
            
            dispatch_async(dispatch_get_main_queue()) {
                self.errorHandler?(event)
                
                if self.retryTimer == nil {
                    self.retryTimer = NSTimer.scheduledTimerWithTimeInterval(self.retryInterval, target: self, selector: #selector(EventSource.open), userInfo: nil, repeats: true)
                }
            }
        }
    }
    
}