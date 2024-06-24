//
//  SignIn.swift
//  NoMADLogin
//
//  Created by Joel Rennich on 9/20/17.
//  Copyright © 2017 Joel Rennich. All rights reserved.
//

import Cocoa
import Security.AuthorizationPlugin
import os.log
import OpenDirectory
import OIDCLite
import CryptoTokenKit
let uiLog = OSLog(subsystem: "menu.nomad.login.ad", category: "UI")
let checkADLog = OSLog(subsystem: "menu.nomad.login.ad", category: "CheckADMech")

protocol UpdateCredentialsFeedbackProtocol {

    func passwordExpiryUpdate(_ passwordExpire:String)
    func credentialsUpdated(_ credentials:Creds)
    func credentialsCheckFailed()
    func kerberosTicketUpdated()
    func kerberosTicketCheckFailed(_ error:NoMADSessionError)
    func adUserUpdated(_ adUser:ADUserRecord)

}

@objc class SignInViewController: NSViewController, DSQueryable, TokenManagerFeedbackDelegate {

    override var nibName: NSNib.Name{

        return "LocalUsersViewController"
    }

    func tokenError(_ err:String){
        updateCredentialsFeedbackDelegate?.credentialsCheckFailed()
        TCSLogWithMark("Token error: \(err)")
        authFail()
    }

    func credentialsUpdated(_ credentials:Creds){
        TCSLogWithMark()
        updateCredentialsFeedbackDelegate?.credentialsUpdated(credentials)
        if let res = mechanismDelegate?.setupHints(fromCredentials: credentials, password: passString ){
            switch res {

            case .success:
                break
            case .failure(let msg):
                TCSLogWithMark(msg)
                authFail(msg)

            }

        }

        var credWithPass = credentials
        credWithPass.password = self.passString
        NotificationCenter.default.post(name: Notification.Name("TCSTokensUpdated"), object: self, userInfo:["credentials":credWithPass])

    }

    struct UsernamePasswordCredentials {
        var username:String?
        var password:String?
    }

    //MARK: - setup properties
    var mech: MechanismRecord?
    var nomadSession: NoMADSession?
    var shortName = ""
    var domainName = ""
    var passString = ""
    var newPassword = ""
    var isDomainManaged = false
    var isSSLRequired = false
    var passChanged = false
    let sysInfo = SystemInfoHelper().info()
    var sysInfoIndex = 0
    let tokenManager = TokenManager()

    var updateCredentialsFeedbackDelegate: UpdateCredentialsFeedbackProtocol?
    var isInUserSpace = false
    var watcher:TKTokenWatcher?

    @objc var visible = true
    override var acceptsFirstResponder: Bool {
        return true
    }
    //MARK: - IB outlets
    @IBOutlet weak var usernameTextField: NSTextField!
    @IBOutlet weak var passwordTextField: NSSecureTextField!
    @IBOutlet weak var localOnlyCheckBox: NSButton!
    @IBOutlet weak var localOnlyView: NSView!
    @IBOutlet var alertTextField:NSTextField!

    @IBOutlet weak var stackView: NSStackView!

//    @IBOutlet weak var domain: NSPopUpButton!
    @IBOutlet weak var signIn: NSButton!
    @IBOutlet weak var imageView: NSImageView!

    var mechanismDelegate:XCredsMechanismProtocol?

//    var mechanism:XCredsMechanismProtocol? {
//        set {
//            TCSLogWithMark()
//            mechanismDelegate=newValue
//        }
//        get {
//            return mechanismDelegate
//        }
//    }

    //MARK: - Migrate Box IB outlets
    var migrate = false
    var migrateUserRecord : ODRecord?
    var didUpdateFail = false
    var setupDone=false
    //MARK: - UI Methods

    override func awakeFromNib() {
        super.awakeFromNib()
        alertTextField.isHidden=true
        TCSLogWithMark()
        //awakeFromNib gets called multiple times. guard against that.
        if setupDone == false {
            setupDone=true
            if let prefDomainName=getManagedPreference(key: .ADDomain) as? String{
                domainName = prefDomainName
            }
            setupLoginAppearance()
        }
        TCSLogWithMark("setting up smart card listener")
                watcher = TKTokenWatcher()
                watcher?.setInsertionHandler({ tokenID in
                    self.watcher?.addRemovalHandler({ tokenID in
                        TCSLogWithMark("card removed")
                    }, forTokenID: tokenID)
                    TCSLogWithMark("card inserted")
                    TCSLogWithMark("getting slotNames")

                    let slotNames = TKSmartCardSlotManager.default?.slotNames
                    TCSLogWithMark("got slotNames")

                    guard let slotNames = slotNames else {
                        TCSLogWithMark("bad slotnames")
                        return
                    }

                    let slotName=slotNames.first { currString in
                        currString.contains("Feitian") && currString.contains("Contactless") 
                    }

                    guard let slotName = slotName else {
                        TCSLogWithMark("bad slotnames")
                        return
                    }
                    TCSLogWithMark()
                    let slot = TKSmartCardSlotManager.default?.slotNamed(slotName)
                    TCSLogWithMark()
                    guard let tkSmartCard = slot?.makeSmartCard() else {
                        return
                    }
                    TCSLogWithMark()
                    let builtInReader = BuiltInPIVCardReader(tkSmartCard: tkSmartCard)
                    TCSLogWithMark()
                    let returnData = builtInReader.sendAPDU(cla: 0xFF, ins: 0xCA, p1: 0, p2: 0, data: nil)
                    TCSLogWithMark()
                    if let returnData=returnData, returnData.count>2{
                        TCSLogWithMark()
                        print(returnData[0...returnData.count-3].hexEncodedString())
                        DispatchQueue.main.async {
                            TCSLogWithMark()
                            let hex=returnData[0...returnData.count-3].hexEncodedString()
                            self.cardLogin(uid: hex)
                        }
                    }

                })


    }

    func cardLogin(uid:String) {
        guard let userArray = UserDefaults.standard.array(forKey: PrefKeys.uidUsers.rawValue) as? Array<Dictionary<String,String>> else {
            TCSLogWithMark("no user preferences for uid. check your profile. \(uid)")
            passwordTextField.shake(self)

            return
        }
        let user = userArray.first { currUser in
            return currUser["uid"]==uid
        }
        guard let user = user,
        let username = user["username"],
        let password = user["password"] else {
            TCSLogWithMark("no users for: \(uid)")
            passwordTextField.shake(self)
            return

        }
        shortName=username
        passString=password
        let userExists = try? PasswordUtils.isUserLocal(shortName)
        guard let userExists = userExists else {
            TCSLogWithMark("DS error")
            passwordTextField.shake(self)
            return
        }
        if (userExists==true){
            //local user exists. try password
            TCSLogWithMark("local user exists. trying password")
            if PasswordUtils.verifyUser(name: shortName, auth: passString)  {
                TCSLogWithMark("local user valid. logging in")

                setRequiredHintsAndContext()
                mechanismDelegate?.setHint(type: .localLogin, hint: true)
                completeLogin(authResult:.allow)
            }
            else {
                TCSLogWithMark("invalid password for user \(shortName)")
                authFail()
            }
        }
        else {
            //new user, so we create the account and move along
            setRequiredHintsAndContext()
            completeLogin(authResult:.allow)
        }

    }
    func setupLoginAppearance() {
        TCSLogWithMark()
        
        alertTextField.isHidden=true

        self.usernameTextField.stringValue=""
        self.passwordTextField.stringValue=""

        self.view.wantsLayer=true
        self.view.layer?.backgroundColor = CGColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 0.4)
        localOnlyCheckBox.isEnabled=true
        localOnlyView.isHidden=false
        // make things look better
        TCSLog("Tweaking appearance")

        if let usernamePlaceholder = UserDefaults.standard.string(forKey: PrefKeys.usernamePlaceholder.rawValue){
            TCSLogWithMark("Setting username placeholder: \(usernamePlaceholder)")
            self.usernameTextField.placeholderString=usernamePlaceholder
        }
        self.usernameTextField.isEnabled=true

        if let passwordPlaceholder = UserDefaults.standard.string(forKey: PrefKeys.passwordPlaceholder.rawValue){
            TCSLogWithMark("Setting password placeholder")

            self.passwordTextField.placeholderString=passwordPlaceholder

        }
        passwordTextField.isEnabled=true
        signIn.isEnabled=true
        TCSLogWithMark("Domain is \(domainName)")
        if UserDefaults.standard.bool(forKey: PrefKeys.shouldShowLocalOnlyCheckbox.rawValue) == false {
            TCSLogWithMark("hiding local only")

            self.localOnlyCheckBox.isHidden = true
            self.localOnlyView.isHidden = true
        }
        else {
            //show based on if there is an AD domain or not

            let isLocalOnly = self.domainName.isEmpty == true && UserDefaults.standard.bool(forKey: PrefKeys.shouldUseROPGForLoginWindowLogin.rawValue) == false
            self.localOnlyCheckBox.isHidden = isLocalOnly
            self.localOnlyView.isHidden = isLocalOnly

        }

    }

    fileprivate func showResetUI() -> Bool {
        TCSLogWithMark()

        let changePasswordWindowController = UpdatePasswordWindowController.init(windowNibName: NSNib.Name("UpdatePasswordWindowController"))


        changePasswordWindowController.window?.canBecomeVisibleWithoutLogin=true
        changePasswordWindowController.window?.isMovable = true
        changePasswordWindowController.window?.canBecomeVisibleWithoutLogin = true
        changePasswordWindowController.window?.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue)
        var isDone = false
        while (!isDone){
            DispatchQueue.main.async{
                TCSLogWithMark("resetting level")
                changePasswordWindowController.window?.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue)
            }

            let response = NSApp.runModal(for: changePasswordWindowController.window!)
            changePasswordWindowController.window?.close()
            TCSLogWithMark("response: \(response.rawValue)")

            if response == .cancel {
                isDone = true
                return false
            }

            if let pass = changePasswordWindowController.password {
                newPassword = pass
            }
            guard let session = nomadSession else {

                TCSLogWithMark("invalid session")
                return false
            }
            session.oldPass = passString
            session.newPass = newPassword
            os_log("Attempting password change for %{public}@", log: uiLog, type: .debug, shortName)
            TCSLogWithMark("Attempting password change")
            passChanged = true

            session.changePassword()

            didUpdateFail = false
            isDone = true
//            delegate?.setHint(type: .migratePass, hint: migrateUIPass)
//            completeLogin(authResult: .allow)
            return true

        }


    }

    fileprivate func authFail(_ message: String?=nil) {
        TCSLogWithMark(message ?? "")
        nomadSession = nil
        passwordTextField.stringValue = ""
        passwordTextField.shake(self)
        alertTextField.isHidden=false
        if message?.lowercased() == "preauthentication failed" {
            alertTextField.stringValue = "Authentication Failed"
        }
        else if message?.lowercased() == "unknown ad user" {
            alertTextField.stringValue = "Authentication Failed"
        }
        else {
            alertTextField.stringValue = message ?? "Authentication Failed"
        }
        setLoginWindowState(enabled: true)
    }

    /// Simple toggle to change the state of the NoLo window UI between active and inactive.
    fileprivate func setLoginWindowState(enabled:Bool) {
        TCSLogWithMark()
        signIn.isEnabled = enabled
        TCSLogWithMark()
        usernameTextField.isEnabled = enabled
        passwordTextField.isEnabled = enabled
        localOnlyCheckBox.isEnabled = enabled

        TCSLogWithMark()
    }


    /// When the sign in button is clicked we check a few things.
    ///
    /// 1. Check to see if the username field is blank, bail if it is. If not, animate the UI and process the user strings.
    ///
    /// 2. Check the user shortname and see if the account already exists in DSLocal. If so, simply set the hints and pass on.
    ///
    /// 3. Create a `NoMADSession` and see if we can authenticate as the user.
    @IBAction func signInButtonPressed(_ sender: Any) {
        TCSLogWithMark("Sign In button pressed")
        let strippedUsername = usernameTextField.stringValue.trimmingCharacters(in:  CharacterSet.whitespaces)

        if strippedUsername.isEmpty {
            usernameTextField.shake(self)
            TCSLogWithMark("No username entered")
            return
        }
        else if passString.isEmpty {
            passwordTextField.shake(self)
            view.window?.makeFirstResponder(passwordTextField)

            TCSLogWithMark("No password entered")
            return
        }
        setLoginWindowState(enabled: false)

        TCSLogWithMark()
        updateLoginWindowInfo()
        TCSLogWithMark()

        if (self.domainName.isEmpty==true && UserDefaults.standard.bool(forKey: PrefKeys.shouldUseROPGForLoginWindowLogin.rawValue) == false) || self.localOnlyCheckBox.state == .on{
            TCSLogWithMark("do local auth only")
            if PasswordUtils.verifyUser(name: shortName, auth: passString)  {
                setRequiredHintsAndContext()
                mechanismDelegate?.setHint(type: .localLogin, hint: true)

                completeLogin(authResult:.allow)

            }
            else {
                TCSLogWithMark("password check failed")
                authFail()
            }
            return
        } else if UserDefaults.standard.bool(forKey: PrefKeys.shouldUseROPGForLoginWindowLogin.rawValue) == true { TCSLogWithMark("Checking credentials using ROPG")

            tokenManager.feedbackDelegate=self

            shortName = strippedUsername
            tokenManager.oidc().requestTokenWithROPG(username: strippedUsername, password: passString)
            return


        }
        else { // AD. So auth
            TCSLogWithMark("network auth.")
            networkAuth()
        }

    }

    fileprivate func networkAuth() {
        nomadSession = NoMADSession.init(domain: domainName, user: shortName)
        TCSLogWithMark("NoMAD Login User: \(shortName), Domain: \(domainName)")
        guard let session = nomadSession else {
            TCSLogErrorWithMark("Could not create NoMADSession from SignIn window")
            return
        }
        session.useSSL = isSSLRequired
        session.userPass = passString
        session.delegate = self
        session.recursiveGroupLookup = getManagedPreference(key: .RecursiveGroupLookup) as? Bool ?? false
        

        if let customLDAPAttributes = getManagedPreference(key: .CustomLDAPAttributes) as? Array<String> {
            TCSLogWithMark("Adding requested Custom Attributes:\(customLDAPAttributes)")
            session.customAttributes=customLDAPAttributes
        }

        if let ignoreSites = getManagedPreference(key: .IgnoreSites) as? Bool {
            os_log("Ignoring AD sites", log: uiLog, type: .debug)

            session.siteIgnore = ignoreSites
        }
        
        if let ldapServers = getManagedPreference(key: .LDAPServers) as? [String] {
            TCSLogWithMark("Adding custom LDAP servers")

            session.ldapServers = ldapServers
        }
        
        TCSLogWithMark("Attempt to authenticate user")
        session.authenticate()
    }


    /// Format the user and domain from the login window depending on the mode the window is in.
    ///
    /// I.e. are we picking a domain from a list, using a managed domain, or putting it on the user name with '@'.
    fileprivate func updateLoginWindowInfo() {

        TCSLogWithMark("Format user and domain strings")
        TCSLogWithMark()
        var providedDomainName = ""

        let strippedUsername = usernameTextField.stringValue.trimmingCharacters(in:  CharacterSet.whitespaces)
        shortName = strippedUsername


        TCSLogWithMark()
        if strippedUsername.range(of:"@") != nil && getManagedPreference(key: .ADDomain) != nil {
            shortName = (strippedUsername.components(separatedBy: "@").first)!

            providedDomainName = strippedUsername.components(separatedBy: "@").last!.uppercased()
            TCSLogWithMark(providedDomainName)
        }
        TCSLogWithMark()
//        if strippedUsername.contains("\\") {
//            os_log("User entered an NT Domain name, doing lookup", log: uiLog, type: .default)
//            if let ntDomains = getManagedPreference(key: .NTtoADDomainMappings) as? [String:String],
//                let ntDomain = strippedUsername.components(separatedBy: "\\").first?.uppercased(),
//                let user = strippedUsername.components(separatedBy: "\\").last,
//                let convertedDomain =  ntDomains[ntDomain] {
//                    shortName = user
//                    providedDomainName = convertedDomain
//            } else {
//                os_log("NT Domain mapping failed, wishing the user luck on authentication", log: uiLog, type: .default)
//            }
//        }
//        if let prefDomainName=getManagedPreference(key: .ADDomain) as? String{
//
//            domainName = prefDomainName
//        }
//        if domainName != "" && providedDomainName.lowercased() == domainName.lowercased() {
//            TCSLogWithMark("ADDomain being used")
//            domainName = providedDomainName.uppercased()
//        }

//        if providedDomainName == domainName {
//
//        }
//        else if !providedDomainName.isEmpty {
//            TCSLogWithMark("Optional domain provided in text field: \(providedDomainName)")
//            if getManagedPreference(key: .AdditionalADDomains) as? Bool == true {
//                os_log("Optional domain name allowed by AdditionalADDomains allow-all policy", log: uiLog, type: .default)
//                domainName = providedDomainName
//                return
//            }
//
//            if let optionalDomains = getManagedPreference(key: .AdditionalADDomains) as? [String] {
//                guard optionalDomains.contains(providedDomainName.lowercased()) else {
//                    TCSLogWithMark("Optional domain name not allowed by AdditionalADDomains whitelist policy")
//                    return
//                }
//                TCSLogWithMark("Optional domain name allowed by AdditionalADDomains whitelist policy")
//                domainName = providedDomainName
//                return
//            }
//
//            TCSLogWithMark("Optional domain not name allowed by AdditionalADDomains policy (false or not defined)")
//        }
        
        if providedDomainName == "",
            let managedDomain = getManagedPreference(key: .ADDomain) as? String {
            TCSLogWithMark("Defaulting to managed domain as there is nothing else")
            domainName = managedDomain
        }

        TCSLogWithMark("Using domain from managed domain")
        return
    }


    //MARK: - Login Context Functions

    /// Set the authorization and context hints. These are the basics we need to passthrough to the next mechanism.
    fileprivate func setRequiredHintsAndContext() {
        TCSLogWithMark()
        TCSLogWithMark("Setting hints for user: \(shortName)")
        mechanismDelegate?.setHint(type: .user, hint: shortName)
        mechanismDelegate?.setHint(type: .pass, hint: passString)
        TCSLogWithMark()
        os_log("Setting context values for user: %{public}@", log: uiLog, type: .debug, shortName)
        mechanismDelegate?.setContextString(type: kAuthorizationEnvironmentUsername, value: shortName)
        mechanismDelegate?.setContextString(type: kAuthorizationEnvironmentPassword, value: passString)
        TCSLogWithMark()

    }


    /// Complete the NoLo process and either continue to the next Authorization Plugin or reset the NoLo window.
    ///
    /// - Parameter authResult:`Authorizationresult` enum value that indicates if login should proceed.
    fileprivate func completeLogin(authResult: AuthorizationResult) {


        switch authResult {
        case .allow:
            TCSLogWithMark("Complete login process with allow")
            mechanismDelegate?.allowLogin()

        case .deny:
            TCSLogWithMark("Complete login process with deny")
            mechanismDelegate?.denyLogin(message:nil)
            NotificationCenter.default.post(name: Notification.Name("TCSTokensUpdated"), object: self, userInfo:["error":"Login Denied","cause":authResult])


        case .userCanceled:
            TCSLogWithMark("Complete login process with deny")
            mechanismDelegate?.denyLogin(message:nil)
            NotificationCenter.default.post(name: Notification.Name("TCSTokensUpdated"), object: self, userInfo:["error":"User Cancelled", "cause":authResult])

        default:
            TCSLogWithMark("deny login process with unknown error")
            mechanismDelegate?.denyLogin(message:nil)
            NotificationCenter.default.post(name: Notification.Name("TCSTokensUpdated"), object: self, userInfo:["error":"Unknown error","cause":authResult])

        }
        TCSLogWithMark()
//        NSApp.stopModal()
    }

    //MARK: - Update Local User Account Methods

//    fileprivate func showPasswordSync() {
//        // hide other possible boxes
//        TCSLogWithMark()
//
//        let passwordWindowController = PromptForLocalPasswordWindowController.init(windowNibName: NSNib.Name("LoginPasswordWindowController"))
//
//        passwordWindowController.window?.canBecomeVisibleWithoutLogin=true
//        passwordWindowController.window?.isMovable = false
//        passwordWindowController.window?.canBecomeVisibleWithoutLogin = true
//        passwordWindowController.window?.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue)
//        var isDone = false
//        while (!isDone){
//            DispatchQueue.main.async{
//                TCSLogWithMark("resetting level")
//                passwordWindowController.window?.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue)
//            }
//
//            let response = NSApp.runModal(for: passwordWindowController.window!)
//            passwordWindowController.window?.close()
//
//            if response == .cancel {
//                isDone=true
//                TCSLogWithMark("User cancelled resetting keychain or entering password. Denying login")
//                completeLogin(authResult: .deny)
//
//                return
//            }
//
//            let localPassword = passwordWindowController.password
//            guard let localPassword = localPassword else {
//                continue
//            }
//            do {
//                os_log("Password doesn't match existing local. Try to change local pass to match.", log: uiLog, type: .default)
//                let localUser = try getLocalRecord(shortName)
//                try localUser.changePassword(localPassword, toPassword: passString)
//                os_log("Password sync worked, allowing login", log: uiLog, type: .default)
//
//                isDone=true
//                mechanism?.setHint(type: .existingLocalUserPassword, hint: localPassword)
//                completeLogin(authResult: .allow)
//                return
//            } catch {
//                os_log("Unable to sync local password to Network password. Reload and try again", log: uiLog, type: .error)
//                return
//            }
//
//
//        }
//
//    }
    

    fileprivate func showMigration(password:String) {

        TCSLogWithMark()
        switch SelectLocalAccountWindowController.selectLocalAccountAndUpdate(newPassword: password) {

        case .successful(let username):
            TCSLogWithMark("Successful local account verification. Allowing")
            shortName = username
            setRequiredHintsAndContext()
            completeLogin(authResult: .allow)
            return

        case .canceled:
            TCSLogWithMark("selectLocalAccountAndUpdate cancelled")
            completeLogin(authResult: .deny)
            return
        case .createNewAccount:
            TCSLogWithMark("selectLocalAccountAndUpdate createNewAccount")
            completeLogin(authResult: .allow)

        case .error(let error):
            TCSLogWithMark("selectLocalAccountAndUpdate error:\(error)")
            completeLogin(authResult: .deny)

        }
        //need to prompt for username and passsword to select an account. Perhaps use code from the cloud login.
//        //RunLoop.main.perform {
//        // hide other possible boxes
//        os_log("Showing migration box", log: uiLog, type: .default)
//
//        self.loginStack.isHidden = true
//        self.signIn.isHidden = true
//        self.signIn.isEnabled = true
//
//        // show migration box
//        self.migrateBox.isHidden = false
//        self.migrateSpinner.isHidden = false
//        self.migrateUsers.addItems(withTitles: self.localCheck.migrationUsers ?? [""])
//        //}
    }
    
//    @IBAction func clickMigrationOK(_ sender: Any) {
//        RunLoop.main.perform {
//            self.migrateSpinner.isHidden = false
//            self.migrateSpinner.startAnimation(nil)
//        }
//        
//        let migrateUIPass = self.migratePassword.stringValue
//        if migrateUIPass.isEmpty {
//            os_log("No password was entered", log: uiLog, type: .error)
//            RunLoop.main.perform {
//                self.migrateSpinner.isHidden = true
//                self.migrateSpinner.stopAnimation(nil)
//            }
//            return
//        }
//        
//        // Take a look to see if we are syncing passwords. Until the next refactor the easiest way to tell is if the picklist is hidden.
//        if self.migrateUsers.isHidden {
//            do {
//                os_log("Password doesn't match existing local. Try to change local pass to match.", log: uiLog, type: .default)
//                let localUser = try getLocalRecord(shortName)
//                try localUser.changePassword(migrateUIPass, toPassword: passString)
//                didUpdateFail = false
//                passChanged = false
//                os_log("Password sync worked, allowing login", log: uiLog, type: .default)
//                delegate?.setHint(type: .existingLocalUserPassword, hint: migrateUIPass)
//                completeLogin(authResult: .allow)
//                return
//            } catch {
//                os_log("Unable to sync local password to Network password. Reload and try again", log: uiLog, type: .error)
//                didUpdateFail = true
//                showPasswordSync()
//                return
//            }
//        }
//        guard let migrateToUser = self.migrateUsers.selectedItem?.title else {
//            os_log("Could not select user to migrate from pick list.", log: uiLog, type: .error)
//            return
//        }
//        do {
//            os_log("Getting user record for %{public}@", log: uiLog, type: .default, migrateToUser)
//            migrateUserRecord = try getLocalRecord(migrateToUser)
//            os_log("Checking existing password for %{public}@", log: uiLog, type: .default, migrateToUser)
//            if migrateUIPass != passString {
//                os_log("No match. Upating local password for %{public}@", log: uiLog, type: .default, migrateToUser)
//                try migrateUserRecord?.changePassword(migrateUIPass, toPassword: passString)
//            } else {
//                os_log("Okta and local passwords matched for %{public}@", log: uiLog, type: .default, migrateToUser)
//            }
//            // Mark the record to add an alias if required
//            os_log("Setting hints for %{public}@", log: uiLog, type: .default, migrateToUser)
//            delegate?.setHint(type: .existingLocalUserName, hint: migrateToUser)
//            delegate?.setHint(type: .existingLocalUserPassword, hint: migrateUIPass)
//            os_log("Allowing login", log: uiLog, type: .default, migrateToUser)
//            completeLogin(authResult: .allow)
//        } catch {
//            os_log("Migration failed with: %{public}@", log: uiLog, type: .error, error.localizedDescription)
//            return
//        }
//        
//        // if we are here, the password didn't work
//        os_log("Unable to migrate user.", log: uiLog, type: .error)
//        self.migrateSpinner.isHidden = true
//        self.migrateSpinner.stopAnimation(nil)
//        self.migratePassword.stringValue = ""
//        self.completeLogin(authResult: .deny)
//    }
//    
//    @IBAction func clickMigrationCancel(_ sender: Any) {
//        passChanged = false
//        didUpdateFail = false
//        completeLogin(authResult: .deny)
//    }
//    
//    @IBAction func clickMigrationNo(_ sender: Any) {
//        // user doesn't want to migrate, so create a new account
//        completeLogin(authResult: .allow)
//    }
    
//    @IBAction func clickMigrationOverwrite(_ sender: Any) {
//        // user wants to overwrite their current password
//        os_log("Password Overwrite selected", log: uiLog, type: .default)
//        localCheck.mech = self.mech
//        delegate?.setHint(type: .passwordOverwrite, hint: true)
//        completeLogin(authResult: .allow)
//    }
    
//    @IBAction func showNetworkConnection(_ sender: Any) {
//        username.isHidden = true
//        guard let windowContentView = self.window?.contentView, let wifiView = WifiView.createFromNib(in: .mainLogin) else {
//            os_log("Error showing network selection.", log: uiLog, type: .debug)
//            return
//        }
//
//        wifiView.frame = windowContentView.frame
//        let completion = {
//            os_log("Finished working with wireless networks", log: uiLog, type: .debug)
//            self.username.isHidden = false
//            self.username.becomeFirstResponder()
//        }
//        wifiView.set(completionHandler: completion)
//        windowContentView.addSubview(wifiView)
//    }
//
//    @IBAction func clickInfo(_ sender: Any) {
//        if sysInfo.count > sysInfoIndex + 1 {
//            sysInfoIndex += 1
//        } else {
//            sysInfoIndex = 0
//        }
//
//        systemInfo.title = sysInfo[sysInfoIndex]
//        os_log("System information toggled", log: uiLog, type: .debug)
//    }
//    func verify() {
//
//            if XCredsBaseMechanism.checkForLocalUser(name: shortName) {
//                TCSLogWithMark()
//                os_log("Verify local user login for %{public}@", log: uiLog, type: .default, shortName)
//
//                if getManagedPreference(key: .DenyLocal) as? Bool ?? false {
//                    os_log("DenyLocal is enabled, looking for %{public}@ in excluded users", log: uiLog, type: .default, shortName)
//
//                    var exclude = false
//
//                    if let excludedUsers = getManagedPreference(key: .DenyLocalExcluded) as? [String] {
//                        if excludedUsers.contains(shortName) {
//                            os_log("Allowing local sign in via exclusions %{public}@", log: uiLog, type: .default, shortName)
//                            exclude = true
//                        }
//                    }
//
//                    if !exclude {
//                        os_log("No exclusions for %{public}@, denying local login. Forcing network auth", log: uiLog, type: .default, shortName)
//                        networkAuth()
//                        return
//                    }
//                }
//                TCSLogWithMark()
//                if PasswordUtils.verifyUser(name: shortName, auth: passString) {
//                    TCSLogWithMark()
//                    os_log("Allowing local user login for %{public}@", log: uiLog, type: .default, shortName)
//                    setRequiredHintsAndContext()
//                    TCSLogWithMark()
//                    completeLogin(authResult: .allow)
//                    return
//                } else {
//                    os_log("Could not verify %{public}@", log: uiLog, type: .default, shortName)
//                    authFail()
//                    return
//                }
//            }
//
//    }

}


//MARK: - NoMADUserSessionDelegate
extension SignInViewController: NoMADUserSessionDelegate {

    func NoMADAuthenticationFailed(error: NoMADSessionError, description: String) {
        updateCredentialsFeedbackDelegate?.kerberosTicketCheckFailed(error)

        TCSLogWithMark("AuthenticationFailed: \(description)")
//        alertTextField.isHidden=false
//        alertTextField.stringValue = description
//        if passChanged {
//            os_log("Password change failed.", log: uiLog, type: .default)
//            os_log("Password change failure description: %{public}@", log: uiLog, type: .error, description)
//            oldPassword.isEnabled = true
//            newPassword.isEnabled = true
//            newPasswordConfirmation.isEnabled = true
//
//            newPassword.stringValue = ""
//            newPasswordConfirmation.stringValue = ""
//
////            alertText.stringValue = "Password change failed"
//            return
//        }
        
        switch error {
        case .PasswordExpired:
            TCSLogErrorWithMark("Password is expired or requires change.")
            if DefaultsOverride().bool(forKey: PrefKeys.shouldPromptForADPasswordChange.rawValue) == false {

                authFail("Password is expired or requires change.")
                return

            }
            let res = showResetUI()

            if res == false { //user cancelled so enable UI
                setLoginWindowState(enabled: true)

            }
            return
        case .OffDomain, .UnknownPrincipal:
            TCSLogErrorWithMark("\(error)")

            if getManagedPreference(key: .LocalFallback) as? Bool ?? false && PasswordUtils.verifyUser(name: shortName, auth: passString)  {
                mechanismDelegate?.setHint(type: .localLogin, hint: true)
                setRequiredHintsAndContext()
                completeLogin(authResult: .allow)
            } else {
                if error == .OffDomain {
                    TCSLogErrorWithMark("AD authentication failed, off domain.")
                    authFail("Cannot reach domain controller")

                }
                else if error == .UnknownPrincipal {
                    TCSLogErrorWithMark("AD authentication failed, Unknown AD User.")
                    authFail("Unknown AD User")
                }
                else {
                    TCSLogErrorWithMark("Unknown Error")
                    authFail("Unknown Error")

                }

            }
        default:
            TCSLogErrorWithMark("NoMAD Login Authentication failed with: \(description):\(error.rawValue)")
//            loginStartedUI()
                authFail(description)
//
            return
        }
    }


    func NoMADAuthenticationSucceded() {
        updateCredentialsFeedbackDelegate?.kerberosTicketUpdated()

        if getManagedPreference(key: .RecursiveGroupLookup) as? Bool ?? false {
            nomadSession?.recursiveGroupLookup = true
        }
        
        if passChanged {
            // need to ensure the right password is stashed
            passString = newPassword
            passChanged = false
        }
        
        TCSLogWithMark("Authentication succeeded, requesting user info")
        if isInUserSpace==true {
            self.view.window?.close()
        }
        nomadSession?.userInfo()
    }

//callback from ADAuth framework when userInfo returns
    func NoMADUserInformation(user: ADUserRecord) {

        TCSLogWithMark("User Info:\(user)")
        TCSLogWithMark("Groups:\(user.groups)")
        var allowedLogin = true
        let dateFormatter = DateFormatter()

        dateFormatter.locale = Locale(identifier: "en_US")
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        if let passExpired = user.passwordExpire {
            let dateString = dateFormatter.string(from: passExpired)
            updateCredentialsFeedbackDelegate?.passwordExpiryUpdate(dateString)

        }
        updateCredentialsFeedbackDelegate?.adUserUpdated(user)

        TCSLogWithMark("Checking for DenyLogin groupsChecking for DenyLogin groups")
        
        if let allowedGroups = getManagedPreference(key: .DenyLoginUnlessGroupMember) as? [String] {
            TCSLogErrorWithMark("Found a DenyLoginUnlessGroupMember key value: \(allowedGroups.debugDescription)")
            
            // set the allowed login to false for now
            
            allowedLogin = false
            
            user.groups.forEach { group in
                if allowedGroups.contains(group) {
                    allowedLogin = true
                    TCSLogErrorWithMark("User is a member of %{public}@ group. Setting allowedLogin = true ")
                }
            }
        }
    
        let mapUID = DefaultsOverride.standardOverride.string(forKey: PrefKeys.mapUID.rawValue)

        if let mapUID = mapUID, let rawAttributes = user.rawAttributes, let uidString = rawAttributes[mapUID]  {
            mechanismDelegate?.setHint(type: .uid, hint: uidString)

        }
        if let ntName = user.customAttributes?["msDS-PrincipalName"] as? String {
            TCSLogWithMark("Found NT User Name: \(ntName)")
            mechanismDelegate?.setHint(type: .ntName, hint: ntName)
        }
        
        if allowedLogin {
            
            setHints(user: user)

            // check for any migration and local auth requirements
            let localCheck = LocalCheckAndMigrate()
            localCheck.isInUserSpace = self.isInUserSpace
            localCheck.delegate = mechanismDelegate
            switch localCheck.migrationTypeRequired(userToCheck: user.shortName, passToCheck: passString, kerberosPrincipalName:user.userPrincipal) {

            case .fullMigration:
                TCSLogWithMark()
                showMigration(password:passString)
            case .syncPassword:
                // first check to see if we can resolve this ourselves
                TCSLogWithMark("Sync password called.")

                let promptPasswordWindowController = VerifyLocalPasswordWindowController()

                promptPasswordWindowController.showResetText=true
                promptPasswordWindowController.showResetButton=true

                if isInUserSpace==true{
                    promptPasswordWindowController.showResetText=false
                    promptPasswordWindowController.showResetButton=false

                }
                var currUser = user.shortName
                TCSLogWithMark("switch  promptPasswordWindowController")
                if isInUserSpace == true {
                    let consoleUser = getConsoleUser()
                    currUser=consoleUser
                }


                switch  promptPasswordWindowController.promptForLocalAccountAndChangePassword(username: currUser, newPassword: passString, shouldUpdatePassword: true) {

                case .success(let enteredUsernamePassword):

                    TCSLogWithMark("setting original password to use to unlock keychain later")

                    if let enteredUsernamePassword = enteredUsernamePassword {
                        mechanismDelegate?.setHint(type: .existingLocalUserPassword, hint:enteredUsernamePassword.password as Any  )
                    }

                    completeLogin(authResult: .allow)

                case .resetKeychainRequested(let usernamePasswordCredentials):
                    TCSLogWithMark("resetKeychainRequested")

                    if let adminUsername = usernamePasswordCredentials?.username, let adminPassword = usernamePasswordCredentials?.password {
                        mechanismDelegate?.setHint(type: .adminUsername, hint:adminUsername )
                        mechanismDelegate?.setHint(type: .adminPassword, hint: adminPassword)
                        mechanismDelegate?.setHint(type: .passwordOverwrite, hint: true)

                    }
                    completeLogin(authResult: .allow)


                case .userCancelled:
                    TCSLogWithMark("userCancelled")

                    completeLogin(authResult: .userCanceled)


                case .error(_):
                    TCSLogWithMark("error")

                    completeLogin(authResult: .deny)
                }

            case .errorSkipMigration(let mesg):
                mechanismDelegate?.denyLogin(message:mesg)
            case .skipMigration, .userMatchSkipMigration, .complete:
                completeLogin(authResult: .allow)
//            case .mappedUserFound(let foundODUserRecord):
//                shortName = foundODUserRecord.recordName
//                TCSLogWithMark("Mapped user found: \(shortName)")
//                setRequiredHintsAndContext()
//                completeLogin(authResult: .allow)
            }
        } else {
            authFail()
            TCSLogWithMark("auth fail")
//            alertText.stringValue = "Not authorized to login."
//            showResetUI()
        }
    }
    
    fileprivate func setHints(user: ADUserRecord) {
        TCSLogWithMark()
        TCSLogWithMark("NoMAD Login Looking up info");
        setRequiredHintsAndContext()
        mechanismDelegate?.setHint(type: .firstName, hint: user.firstName)
        mechanismDelegate?.setHint(type: .lastName, hint: user.lastName)
        mechanismDelegate?.setHint(type: .noMADDomain, hint: domainName)
        mechanismDelegate?.setHint(type: .groups, hint: user.groups)
        mechanismDelegate?.setHint(type: .fullName, hint: user.cn)
        TCSLogWithMark("setting kerberos principal to \(user.userPrincipal)")

        mechanismDelegate?.setHint(type: .kerberos_principal, hint: user.userPrincipal)
        mechanismDelegate?.setHint(type: .ntName, hint: user.ntName)

        // set the network auth time to be added to the user record
        mechanismDelegate?.setHint(type: .networkSignIn, hint: String(describing: Date.init().description))

        if let userAttributes = user.rawAttributes{
            TCSLogWithMark("Setting AD user attributes")
            mechanismDelegate?.setHint(type: .allADAttributes, hint:userAttributes )

        }

    }

}


//MARK: - NSTextField Delegate
extension SignInViewController: NSTextFieldDelegate {
    public func controlTextDidChange(_ obj: Notification) {
        let passField = obj.object as! NSTextField
        if passField.tag == 99 {
            passString = passField.stringValue
        }
    }
}


//MARK: - ContextAndHintHandling Protocol
//extension SignIn: ContextAndHintHandling {}

extension NSWindow {

    func shakeWindow(){
        let numberOfShakes      = 3
        let durationOfShake     = 0.25
        let vigourOfShake : CGFloat = 0.015

        let frame : CGRect = self.frame
        let shakeAnimation :CAKeyframeAnimation  = CAKeyframeAnimation()

        let shakePath = CGMutablePath()
        shakePath.move(to: CGPoint(x: frame.minX, y: frame.minY))

        for _ in 0...numberOfShakes-1 {
            shakePath.addLine(to: CGPoint(x: frame.minX - frame.size.width * vigourOfShake, y: frame.minY))
            shakePath.addLine(to: CGPoint(x: frame.minX + frame.size.width * vigourOfShake, y: frame.minY))
        }

        shakePath.closeSubpath()

        shakeAnimation.path = shakePath;
        shakeAnimation.duration = durationOfShake;

        self.animations = [NSAnimatablePropertyKey("frameOrigin"):shakeAnimation]
        self.animator().setFrameOrigin(self.frame.origin)
    }

}

