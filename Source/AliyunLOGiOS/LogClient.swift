//
//  LOGClient.swift
//  AliyunLOGiOS
//
//  Created by 王佳玮 on 16/7/29.
//  edited by zhuoqin on 17/11/20
//  Copyright © 2016年 wangjwchn. All rights reserved.

import Foundation
public class LOGClient: NSObject {
    var mEndPoint: String
    var mAccessKeyID: String
    var mAccessKeySecret: String
    var mProject: String
    var mAccessToken: String?
    
    //重试相关逻辑
    var retryCount: Int
    let retryMax: Int = 3
    
    public var mIsLogEnable: Bool = false
    fileprivate var cacheManager: CacheCheckManager?
    public var mConfig: SLSConfig?
    
    public init(endPoint:String,accessKeyID:String,accessKeySecret :String,projectName:String, token: String? = nil, config: SLSConfig = SLSConfig()){
        if( endPoint.range(of: "http://") != nil ||
            endPoint.range(of: "Http://") != nil ||
            endPoint.range(of: "HTTP://") != nil){
            mEndPoint = endPoint.substring(from: endPoint.characters.index(endPoint.startIndex, offsetBy: 7))
        } else if( endPoint.range(of: "https://") != nil ||
            endPoint.range(of: "Https://") != nil ||
            endPoint.range(of: "HTTPS://") != nil){
            mEndPoint = endPoint.substring(from: endPoint.characters.index(endPoint.startIndex, offsetBy: 8))
        } else{
            mEndPoint = endPoint
        }
        
        mAccessKeyID = accessKeyID
        mAccessKeySecret = accessKeySecret
        mProject = projectName
        retryCount = 0
        mConfig = config
        mAccessToken = token
        
        super.init()
        
        cacheManager = CacheCheckManager(client: self)
        cacheManager?.startCacheCheck()
    }
    
    
    public convenience init(endPoint:String, accessKeyID:String, accessKeySecret:String, token:String, projectName:String, config: SLSConfig){
        self.init(endPoint: endPoint, accessKeyID: accessKeyID, accessKeySecret: accessKeySecret, projectName: projectName, token: token, config: config)
    }
    
    open func SetToken(_ token:String){
        //        guard token != "" else{
        //            throw LogError.nullToken
        //        }
        mAccessToken = token
    }
    open func GetToken() -> String?{
        return mAccessToken
    }
    open func GetEndPoint() -> String{
        return mEndPoint
    }
    open func GetKeyID() -> String{
        return mAccessKeyID
    }
    open func GetKeySecret() ->String{
        return mAccessKeySecret
    }
    open func PostLog(_ logGroup:LogGroup,logStoreName:String, call: @escaping (URLResponse?, NSError?) -> ()){
        
        DispatchQueue.global(qos: .default).async(execute: {
            
            let httpUrl = "https://\(self.mProject).\(self.mEndPoint)"+"/logstores/\(logStoreName)/shards/lb"
            let jsonpackage = logGroup.GetJsonPackage()
            let httpPostBody = jsonpackage.data(using: String.Encoding.utf8)!
            let httpPostBodyZipped = httpPostBody.GZip!
            
            let httpHeaders = self.GetHttpHeadersFrom(logStoreName,url: httpUrl,body: httpPostBody,bodyZipped: httpPostBodyZipped)
            
            self.HttpPostRequest(httpUrl, headers: httpHeaders, body: httpPostBodyZipped, callBack: {[weak self] (result, error) in
                if (error != nil && (self?.mConfig?.isCachable)!) {
                    let timestamp = Date.timeIntervalBetween1970AndReferenceDate
                    DBManager.defaultManager().insertRecords(endpoint: (self?.mEndPoint)!, project: (self?.mProject)!, logstore: logStoreName, log: jsonpackage, timestamp: timestamp)
                }
                call(result, error)
            })
        })
    }
    
    open func PostLogInCache(logstore: String, logMsg: String, call: @escaping (URLResponse?, NSError?) -> ()){
        
        DispatchQueue.global(qos: .default).async(execute: {
            
            let httpUrl = "https://\(self.mProject).\(self.mEndPoint)"+"/logstores/\(logstore)/shards/lb"
            
            let httpPostBody = logMsg.data(using: .utf8)!
            let httpPostBodyZipped = httpPostBody.GZip!
            
            let httpHeaders = self.GetHttpHeadersFrom(logstore , url: httpUrl, body: httpPostBody, bodyZipped: httpPostBodyZipped)
            
            self.HttpPostRequest(httpUrl, headers: httpHeaders, body: httpPostBodyZipped, callBack: call)
        })
    }
    
    fileprivate func GetHttpHeadersFrom(_ logstore:String,url:String,body:Data,bodyZipped:Data) -> [String:String]{
        var headers = [String:String]()
        
        headers[KEY_LOG_APIVERSION] = POST_VALUE_LOG_APIVERSION
        headers[KEY_LOG_SIGNATUREMETHOD] = POST_VALUE_LOG_SIGNATUREMETHOD
        headers[KEY_CONTENT_TYPE] = POST_VALUE_LOG_CONTENTTYPE
        headers[KEY_DATE] = Date().GMT
        headers[KEY_CONTENT_MD5] = bodyZipped.md5
        headers[KEY_CONTENT_LENGTH] = "\(bodyZipped.count)"
        headers[KEY_LOG_BODYRAWSIZE] = "\(body.count)"
        headers[KEY_LOG_COMPRESSTYPE] = POST_VALUE_LOG_COMPRESSTYPE
        headers[KEY_HOST] = self.getHostIn(url)
        headers["User-Agent"] = "aliyun-log-sdk-ios/1.2.0"
        
        
        
        var signString = "POST"+"\n"
        signString += headers[KEY_CONTENT_MD5]! + "\n"
        signString += headers[KEY_CONTENT_TYPE]! + "\n"
        signString += headers[KEY_DATE]! + "\n"
        
        if(mAccessToken != nil)
        {
            headers[KEY_ACS_SECURITY_TOKEN] = mAccessToken!
            signString += "\(KEY_ACS_SECURITY_TOKEN):\(headers[KEY_ACS_SECURITY_TOKEN]!)\n"
        }
        
        signString += "\(KEY_LOG_APIVERSION):0.6.0\n"
        signString += "\(KEY_LOG_BODYRAWSIZE):\(headers[KEY_LOG_BODYRAWSIZE]!)\n"
        signString += "\(KEY_LOG_COMPRESSTYPE):\(POST_VALUE_LOG_COMPRESSTYPE)\n"
        signString += "\(KEY_LOG_SIGNATUREMETHOD):\(POST_VALUE_LOG_SIGNATUREMETHOD)\n"
        signString += "/logstores/\(logstore)/shards/lb"
        let sign  =  hmac_sha1(signString, key: mAccessKeySecret)
        
        headers[KEY_AUTHORIZATION] = "LOG \(mAccessKeyID):\(sign)"
        return headers
    }
    
    private func HttpPostRequest(_ url: String,headers: [String:String],body: Data, callBack: @escaping (URLResponse?, NSError?) -> ()){
        
        let NSurl: URL = URL(string: url)!
        
        var request = URLRequest(url: NSurl)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.httpBody=body
        request.httpShouldHandleCookies=false
        
        for (key, val) in headers {
            request.setValue(val, forHTTPHeaderField: key)
            self.logDebug("request header key : ", key , " val : ", val)
        }
        
        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config)
        
        self.logDebug("request : ", request)
        
        session.dataTask(with: request, completionHandler: {(data: Data?, response: URLResponse?, error: Error?)  in
            self.logDebug("response header : " , response.debugDescription)
            var responseBody:String?
            if (data != nil){
                responseBody = String(data:data!, encoding: String.Encoding.utf8)!
            }
            self.logDebug("response body  : ", responseBody ?? "")
            self.logDebug("error : ", error.debugDescription)
        
            var nsError:NSError?
            if (error != nil){
                nsError = error as NSError?
                if (nsError == nil){
                    nsError = NSError(
                        domain: "AliyunLOGError",
                        code: 10001,
                        userInfo: [
                            NSLocalizedDescriptionKey: error.debugDescription
                        ]
                    )
                }
                callBack(response, nsError)
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse{
                self.logDebug("ready check retry")
                let needRetry = self.shouldRetry(httpResponse:httpResponse,retryCount:(self.retryCount))
                if needRetry {
                    self.logDebug("need retry")
                    self.retryCount += 1
                    self.HttpPostRequest(url, headers:headers, body:body, callBack:callBack)
                }else{
                    if (httpResponse.statusCode > 300){
                        let jsonArr = try! JSONSerialization.jsonObject(with:data!,
                                                                        options: JSONSerialization.ReadingOptions.mutableContainers) as! [String: String]
                        if (jsonArr.count > 0){
                            let errorCode = jsonArr["errorCode"]
                            let errorMessage = jsonArr["errorMessage"]
                            let requestID = httpResponse.allHeaderFields["x-log-requestid"]
                            let userInfo = "errorCode : " + String(describing: errorCode) + " errorMessage : " + String(describing: errorMessage) + " requestID : " + String(describing: requestID)
                            nsError = NSError(
                                domain: "AliyunLOGError",
                                code: 10002,
                                userInfo: [
                                    NSLocalizedDescriptionKey: userInfo
                                ]
                            )
                        }
                    }
                }
                callBack(response, nsError)
            }else{
                callBack(response, nsError)
            }
        }).resume()
    }
    
    fileprivate func hmac_sha1(_ text:String, key:String)->String {
        
        let keydata =  key.data(using: String.Encoding.utf8)!
        let keybytes = (keydata as NSData).bytes
        let keylen = keydata.count
        
        let textdata = text.data(using: String.Encoding.utf8)!
        let textbytes = (textdata as NSData).bytes
        let textlen = textdata.count
        
        let resultlen = Int(CC_SHA1_DIGEST_LENGTH)
        let result = UnsafeMutablePointer<CUnsignedChar>.allocate(capacity: resultlen)
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1), keybytes, keylen, textbytes, textlen, result)
        
        let resultData = Data(bytes: UnsafePointer<UInt8>(result), count: resultlen)
        let base64String = resultData.base64EncodedString(options: NSData.Base64EncodingOptions(rawValue: 0))
        
        result.deinitialize()
        return base64String
    }
    
    private func getHostIn(_ url:String)->String {
        var host = url
        if let idx = url.range(of: "://") {
            host = host.substring(from: url.index(idx.lowerBound, offsetBy: 3))
        }
        if let idx = host.range(of: "/") {
            host = host.substring(to: idx.lowerBound)
        }
        return host;
    }
    
    /*
     *  判断是否需要重试。
     *  目前重试的逻辑是当返回的responsecode >= 500才进行重试，其他的暂不重试。
     *  1.  服务器内部错误造成的的500 response
     */
    private func shouldRetry(httpResponse:HTTPURLResponse, retryCount:Int) -> Bool{
        if (retryCount >= retryMax){
            return  false
        }
        let statusCode = httpResponse.statusCode
        if (statusCode >= 500){
            return  true
        }
        return false;
    }
    
    private func logDebug(_ items: Any..., separator: String = " ") {
        if mIsLogEnable {
            print("Debug: ", terminator: separator)
            items.forEach({ (item) in
                print(item, terminator: separator)
            })
            print()
        }
    }
}

