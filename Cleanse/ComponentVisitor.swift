//
//  ComponentVisitor.swift
//  Cleanse
//
//  Created by Mike Lewis on 5/2/16.
//  Copyright © 2016 Square, Inc. All rights reserved.
//

import Foundation

class VisitorState<V: ComponentVisitor> {
    private var enqueuedRequirementFutures = [Any.Type]()
    /// These are for errors that make it impossible to traverse the module hierarchy
    private var accumulatedErrors  = [CleanseError]()
    
    private var inOverridesMode = false
    
    private var proxyObjectProviders = Dictionary<ProxyTypeKey, AnyProvider>()
    
    init() {
    }
    
    private func appendError<Element: CleanseError>(error error: Element) {
        self.accumulatedErrors.append(error)
    }
}

private struct ProxyTypeKey : TypeKeyProtocol {
    let type: Any.Type
    
    init(_ type: Any.Type) {
        self.type = type
    }
}

protocol ComponentVisitor : Binder {
    /// Used to track state for binder
    var visitorState: VisitorState<Self> { get set }
    
    /// Have to implement this to have a return value for a provider. Default implementation explodes
    func resolveProvider<Element>(_ type: Element.Type, requiredBy: Any.Type?) -> Provider<Element>
    func enterModule<M: Module>(module module: M)
    func leaveModule<M: Module>(module module: M)

    func enterSubcomponent<S: Subcomponent>(dependency dependency: S)
    func leaveSubcomponent<S: Subcomponent>(dependency dependency: S)

    func enterProvider(binding binding: RawProviderBinding)
    func leaveProvider(binding binding: RawProviderBinding)
    
    func visitRequirement(requirement requirement: Any.Type, binding: RawProviderBinding)
}

extension ComponentVisitor {
    func enterModule<M : Module>(module module: M) {
    }
    
    func leaveModule<M : Module>(module module: M) {
    }
    
    func enterProvider(binding binding: RawProviderBinding) {
    }
    
    func leaveProvider(binding binding: RawProviderBinding) {
    }

    func enterSubcomponent<S: Subcomponent>(dependency dependency: S) {
    }

    func leaveSubcomponent<S: Subcomponent>(dependency dependency: S) {
    }

    func visitRequirement(requirement requirement: Any.Type, binding: RawProviderBinding) {
    }
}

extension Subcomponent {
    private func doComponentVisit<V: ComponentVisitor>(visitor visitor: V) {
        visitor.enterSubcomponent(dependency: self)
        configure(binder: visitor)
        visitor.leaveSubcomponent(dependency: self)
    }
}

extension ComponentVisitor {
     func _internalBind(binding binding: RawProviderBinding) {
        enterProvider(binding: binding)
        
        let requirements = visitorState.enqueuedRequirementFutures
        defer { visitorState.enqueuedRequirementFutures.removeAll() }
        
        for requirement in requirements {
            visitRequirement(requirement: requirement, binding: binding)
        }
        
        leaveProvider(binding: binding)
    }

    
    func install<M : Module>(module module: M) {
        enterModule(module: module)
        module.configure(binder: self)
        leaveModule(module: module)
    }

    func install<S : Subcomponent>(dependency dependency: S) {
        enterSubcomponent(dependency: dependency)
        dependency.configure(binder: self)
        leaveSubcomponent(dependency: dependency)
    }

    func _internalProvider<Element>(_ type: Element.Type, debugInfo: ProviderRequestDebugInfo?) -> Provider<Element> {
        visitorState.enqueuedRequirementFutures.append(Element.self)
        
        return resolveProvider(Element.self, requiredBy: debugInfo?.providerRequiredFor)
    }
    
    func resolveProvider<Element>(_ type: Element.Type, requiredBy: Any.Type?) -> Provider<Element> {
        if let existingProxy = visitorState.proxyObjectProviders[ProxyTypeKey(type)]?.asCheckedProvider(type) {
            return existingProxy
        }

        return Provider {
            preconditionFailure("Cannot call synthesized provider. Invalid requested type: \(Element.self). Depended on by \(requiredBy!)"); _ = ()
        }
    }
    
    func _internalWithOverrides(@noescape closure closure: () -> ()) {
        let oldModeMode = visitorState.inOverridesMode
        defer { visitorState.inOverridesMode = oldModeMode }
        
        visitorState.inOverridesMode = true
        
        closure()
    }
}
