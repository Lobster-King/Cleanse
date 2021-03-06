//
//  Resolver.swift
//  CleansecFramework
//
//  Created by Sebastian Edward Shanus on 5/13/20.
//  Copyright © 2020 Square. All rights reserved.
//

import Foundation

/**
 Responsible for creating the resulting DAG and performing core validation/resolution steps.
 */
public struct Resolver {
    /// Resolves and validates all root components in the provided `LinkedInterface`.
    ///
    /// - parameter interface: `LinkedInterface` used to perform resolution.
    /// - returns: List of all root components as `ResolvedComponent` instances.
    ///
    public static func resolve(interface: LinkedInterface) -> [ResolvedComponent] {
        let modulesByName = interface.modules.reduce(into: [String:LinkedModule]()) { (dict, module) in
            if let existing = dict[module.type] {
                dict[module.type] = existing.merge(from: module)
            } else {
                dict[module.type] = module
            }
        }
        let componentsByName = interface.components.reduce(into: [String:LinkedComponent]()) { (dict, c) in
            if let existing = dict[c.type] {
                dict[c.type] = existing.merge(from: c)
            } else {
                dict[c.type] = c
            }
        }
        
        var diagnostics: [ResolutionError] = []
        return componentsByName
            .values
            .filter { $0.isRoot }
            .map { $0.resolve(modulesByName: modulesByName, componentsByName: componentsByName, diagnostics: &diagnostics) }
    }
}

// Helper object for exposing bindings created in ancestor scopes.
fileprivate class ComponentBindings {
    let parent: ComponentBindings?
    let providersByType: [TypeKey:[CanonicalProvider]]
    
    init(providersByType: [TypeKey:[CanonicalProvider]], parent: ComponentBindings? = nil) {
        self.providersByType = providersByType
        self.parent = parent
    }
    
    func provider(for type: TypeKey) -> CanonicalProvider? {
        return providersByType[type]?.first ?? parent?.provider(for: type)
    }
}

fileprivate extension LinkedComponent {
    func resolve(modulesByName: [String:LinkedModule], componentsByName: [String:LinkedComponent], parentBindings: ComponentBindings? = nil, diagnostics: inout [ResolutionError]) -> ResolvedComponent {
        let includedModules = resolveIncludedModules(modulesByName: modulesByName, diagnostics: &diagnostics)
        let installedSubcomponents = resolveSubcomponents(componentsByName, with: includedModules, diagnostics: &diagnostics)
        let providersByType = createUniqueProvidersMap(includedModules: includedModules, installedSubcomponents: installedSubcomponents, diagnostics: &diagnostics)

        let componentBindings = ComponentBindings(providersByType: providersByType, parent: parentBindings)
        // Added dependency is the component's `rootType`. We need to make sure there is a binding for the root object.
        
        let suggestedModulesByType = modulesByName.values.reduce(into: [TypeKey:[LinkedModule]]()) { (result, module) in
            result.merge(
                module.providers.map { $0.mapToCanonical() }.reduce(into: [TypeKey:[LinkedModule]](), { (inner, provider) in
                    inner[provider.type] = [module]
                })) { (l, r) -> [LinkedModule] in
                l + r
            }
        }
        componentBindings.resolveDependencies(
            additionalDependencies: [TypeKey(type: rootType)],
            diagnostics: &diagnostics,
            suggestedModulesByType: suggestedModulesByType
        )
        
        componentBindings.resolveAcyclicGraph(
            root: TypeKey(type: rootType),
            diagnostics: &diagnostics
        )
        
        let children = installedSubcomponents
            .map { $0.resolve(
                modulesByName: modulesByName,
                componentsByName: componentsByName,
                parentBindings: componentBindings,
                diagnostics: &diagnostics
                )
            }
        
        let resolvedComponent = ResolvedComponent(
            type: type,
            providersByType: providersByType,
            children: children,
            diagnostics: diagnostics)
        
        children.forEach { (child) in
            child.parent = resolvedComponent
        }
        
        return resolvedComponent
    }

    // Resolves all directly and transitively included modules in a given component.
    func resolveIncludedModules(modulesByName: [String:LinkedModule], diagnostics: inout [ResolutionError]) -> [LinkedModule] {
        var seenModules = Set(includedModules)
        var moduleSearchQueue = Array(seenModules)
        var foundModules: [LinkedModule] = []
        
        while !moduleSearchQueue.isEmpty {
            let top = moduleSearchQueue.remove(at: 0)
            if let foundModule = modulesByName[top] {
                foundModules.append(foundModule)
                let uniqueIncludedModules = Set(foundModule.includedModules).subtracting(seenModules)
                seenModules.formUnion(uniqueIncludedModules)
                moduleSearchQueue.append(contentsOf: uniqueIncludedModules)
            } else {
                diagnostics.append(ResolutionError(type: .missingModule(top)))
            }
        }
        
        return foundModules
    }
    
    // Resolves all directly and transitively installed subcomponents in a given component.
    func resolveSubcomponents(_ componentsByName: [String:LinkedComponent], with modules: [LinkedModule], diagnostics: inout [ResolutionError]) -> [LinkedComponent] {
        var foundSubcomponents: [LinkedComponent] = []
        
        let installedSubcomponents = Set(subcomponents + modules.flatMap { $0.subcomponents })
        installedSubcomponents.forEach { c in
            if let foundComponent = componentsByName[c] {
                foundSubcomponents.append(foundComponent)
            } else {
                diagnostics.append(ResolutionError(type: .missingSubcomponent(c)))
            }
        }
        
        return foundSubcomponents
    }
    
    func createUniqueProvidersMap(includedModules: [LinkedModule], installedSubcomponents: [LinkedComponent], diagnostics: inout [ResolutionError]) -> [TypeKey:[CanonicalProvider]] {
        var allCanonicalProviders = (providers + includedModules.flatMap { $0.providers }).map { $0.mapToCanonical() }
        allCanonicalProviders.append(seedProvider)
        allCanonicalProviders.append(contentsOf: installedSubcomponents.map { $0.componentFactoryProvider} )
        
        let providersByType = allCanonicalProviders.reduce(into: [TypeKey:[CanonicalProvider]](), { (dict, provider) in
            dict[provider.type, default: []].append(provider)
        })
        
        let duplicateProviderErrors = providersByType.values.compactMap { (providers) -> ResolutionError? in
            guard providers.count > 1 else {
                return nil
            }
            if providers.allSatisfy({ $0.isCollectionProvider }) {
                return nil
            }
            return ResolutionError(type: .duplicateProvider(providers))
        }
        
        diagnostics.append(contentsOf: duplicateProviderErrors)
        
        return providersByType
    }
}

extension ComponentBindings {
    func resolveDependencies(additionalDependencies: [TypeKey], diagnostics: inout [ResolutionError], suggestedModulesByType: [TypeKey:[LinkedModule]]) {
        providersByType.flatMap { $0.value }.forEach { binding in
            let missingDependencyErrors = binding.dependencies.flatMap { d -> [ResolutionError] in
                var errors: [ResolutionError] = []
                if provider(for: d) == nil {
                    let suggestedModules = (suggestedModulesByType[d] ?? []).map { $0.type }
                    errors.append(ResolutionError(type: .missingProvider(dependency: d, dependedUpon: binding, suggestedModules: suggestedModules)))
                }
                return errors
            }
            diagnostics.append(contentsOf: missingDependencyErrors)
        }
        
        additionalDependencies.forEach { dependency in
            if provider(for: dependency) == nil {
                diagnostics.append(ResolutionError(type: .missingProvider(dependency: dependency, dependedUpon: nil)))
            }
        }
    }
    
    func resolveAcyclicGraph(root: TypeKey, diagnostics: inout [ResolutionError]) {
        var resolvedNodes = Set<TypeKey>()
        traverseDependency(root, ancestors: [], resolved: &resolvedNodes, diagnostics: &diagnostics)
    }
    
    func traverseDependency(
        _ type: TypeKey,
        ancestors: [TypeKey],
        resolved: inout Set<TypeKey>,
        diagnostics: inout [ResolutionError]) {
        
        if resolved.contains(type) || type.isWeakProvider {
            return
        }
        
        if let cycleIdx = ancestors.firstIndex(of: type) {
            resolved.insert(type)
            let chain = Array(ancestors[cycleIdx...]) + [type]
            diagnostics.append(ResolutionError(type: .cyclicalDependency(chain: chain)))
            return
        }
        
        // Some dependencies may not exist since they come from ancestor scopes. This is okay
        // as it isn't possible for a cycle to exist across component boundaries.
        guard let deps = providersByType[type] else {
            return
        }
        
        deps
            .flatMap { $0.dependencies }
            .forEach { traverseDependency($0, ancestors: ancestors + [type], resolved: &resolved, diagnostics: &diagnostics) }
        
        resolved.insert(type)
    }
}
