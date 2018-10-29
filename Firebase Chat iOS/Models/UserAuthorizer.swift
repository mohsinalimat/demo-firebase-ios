//
//  UserAuthorizer.swift
//  Firebase Chat iOS
//
//  Created by Eugen Pivovarov on 10/9/18.
//  Copyright © 2018 Virgil Security. All rights reserved.
//

import FirebaseAuth
import VirgilE3Kit

class UserAuthorizer {
    func signIn(completion: @escaping (Bool) -> ()) {
        if let user = Auth.auth().currentUser, let email = user.email {
            let identity = email.replacingOccurrences(of: "@virgilfirebase.com", with: "")
            user.getIDToken { token, error in
                guard error == nil, let token = token else {
                    Log.error("Get ID Token with error: \(error?.localizedDescription ?? "unknown error")")
                    completion(false)
                    return
                }

                let tokenCallback = self.makeTokenCallback(identity: identity, firebaseToken: token)
                VirgilHelper.initialize(tokenCallback: tokenCallback) { error in
                    guard error == nil else {
                        Log.error("Virgil init with error: \(error!.localizedDescription)")
                        completion(false)
                        return
                    }
                    CoreDataHelper.sharedInstance.setUpAccount(withIdentity: identity)

                    completion(true)
                }
            }
        } else {
            completion(false)
        }
    }

    func signIn(identity: String, password: String, completion: @escaping (Error?) -> ()) {
        let email = self.makeFakeEmail(from: identity)
        Auth.auth().signIn(withEmail: email, password: password) { authDataResult, error in
            guard let authDataResult = authDataResult, error == nil else {
                completion(error)
                return
            }
            authDataResult.user.getIDToken { token, error in
                guard error == nil, let token = token else {
                    completion(error)
                    return
                }

                self.setUpVirgil(identity: identity, password: password, token: token) { error in
                    guard error == nil else {
                        completion(error)
                        return
                    }
                    CoreDataHelper.sharedInstance.setUpAccount(withIdentity: identity)

                    completion(nil)
                }
            }
        }
    }

    func signUp(identity: String, password: String, completion: @escaping (Error?) -> ()) {
        let email = self.makeFakeEmail(from: identity)
        Auth.auth().createUser(withEmail: email, password: password) { authDataResult, error in
            guard let authDataResult = authDataResult, error == nil else {
                completion(error)
                return
            }

            let reverseCreatingUser = {
                authDataResult.user.delete { err in
                    if let err = err {
                        Log.error("User deletion failed after signUp with error: \(err.localizedDescription)")
                    }
                }
            }

            authDataResult.user.getIDToken { token, error in
                guard error == nil, let token = token else {
                    reverseCreatingUser()
                    completion(error)
                    return
                }

                self.setUpVirgil(identity: identity, password: password, token: token) { error in
                    guard error == nil else {
                        reverseCreatingUser()
                        completion(error)
                        return
                    }

                    CoreDataHelper.sharedInstance.createAccount(withIdentity: identity)
                    self.setUpFirestore(identity: identity, completion: completion)
                }
            }
        }
    }

    // MARK: - Private API

    private func setUpFirestore(identity: String, completion: @escaping (Error?) -> ()) {
        FirestoreHelper.sharedInstance.doesUserExist(withUsername: identity) { exist in
            if !exist {
                FirestoreHelper.sharedInstance.createUser(identity: identity) { error in
                    guard error == nil else {
                        Log.error("Firebase: creating user failed with error: \(error!.localizedDescription)")
                        completion(error)
                        return
                    }

                    completion(nil)
                }
            }
        }
    }

    private func setUpVirgil(identity: String, password: String, token: String, completion: @escaping (Error?) -> ()) {
        let tokenCallback = makeTokenCallback(identity: identity, firebaseToken: token)
        VirgilHelper.initialize(tokenCallback: tokenCallback) { error in
            guard error == nil else {
                completion(error)
                return
            }

            VirgilHelper.sharedInstance.bootstrap(password: password) { error in
                completion(error)
            }
        }
    }

    private func makeTokenCallback(identity: String, firebaseToken token: String) -> EThree.RenewJwtCallback {
        let tokenCallback: EThree.RenewJwtCallback = { completion in
            let connection = ServiceConnection()
            let jwtRequest = try? ServiceRequest(url: URL(string: AppDelegate.jwtEndpoint)!,
                                                 method: ServiceRequest.Method.post,
                                                 headers: ["Content-Type": "application/json",
                                                           "Authorization": "Bearer " + token],
                                                 params: ["identity": identity])
            guard let request = jwtRequest,
                let jwtResponse = try? connection.send(request),
                let responseBody = jwtResponse.body,
                let json = try? JSONSerialization.jsonObject(with: responseBody, options: []) as? [String: Any],
                let jwtStr = json?["token"] as? String else {
                    Log.error("Getting JWT failed")
                    completion(nil, NSError())
                    return
            }

            completion(jwtStr, nil)
        }

        return tokenCallback
    }

    private func makeFakeEmail(from id: String) -> String {
        return id + "@virgilfirebase.com"
    }
}
