//===----------------------------------------------------------------------===//
//
// This source file is part of the fishy-actor-transport open source project
//
// Copyright (c) 2021 Apple Inc. and the fishy-actor-transport project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of fishy-actor-transport project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation

public final class SourceGen {
  static let header = String(
    """
    // DO NOT MODIFY: This file will be re-generated automatically.
    // Source generated by FishyActorsGenerator (version x.y.z)
    import _Distributed
    
    import FishyActorTransport
    import ArgumentParser
    import Logging
    
    import func Foundation.sleep
    import struct Foundation.Data
    import class Foundation.JSONDecoder
    
    
    """)

  var buckets: Int

  public init(buckets: Int) {
    self.buckets = 1 // TODO: hardcoded for now, would use bucketing approach to avoid re-generating too many sources

    // TODO: Don't do this in init
    // Just make sure all "buckets" exist
//    for i in (0..<buckets) {
//      let path = targetFilePath(targetDirectory: targetDirectory, i: i)
//      try! SourceGen.header.write(to: path, atomically: true, encoding: .utf8)
//    }
  }

  public func generate(decl: DistributedActorDecl) -> [String] {
    return [try! generateSources(for: decl)]
  }

  //*************************************************************************************//
  //************************** CAVEAT ***************************************************//
  //** A real implementation would utilize SwiftSyntaxBuilders rather than just String **//
  //** formatting.                                                                     **//
  //** See: https://github.com/apple/swift-syntax/tree/main/Sources/SwiftSyntaxBuilder **//
  //*************************************************************************************//

  private func generateSources(for decl: DistributedActorDecl) throws -> String {
    var sourceText = SourceGen.header

    sourceText += """
      extension \(decl.name): FishyActorTransport.MessageRecipient {
      """
    sourceText += "\n"
    // ==== Generate message representation,
    // In our sample representation we do so by:
    // --- for each distributed function
    // -- emit a `case` that represents the function
    //
    sourceText += """
        enum _Message: Sendable, Codable {

      """

    for fun in decl.funcs {
      sourceText += "    case \(fun.name)"
      guard !fun.params.isEmpty else {
        sourceText += "\n"
        continue
      }
      sourceText += "("

      var first = true
      for (label, _, type) in fun.params {
        sourceText += first ? "" : ", "
        if let label = label, label != "_" {
          sourceText += "\(label): \(type)"
        } else {
          sourceText += type
        }

        first = false
      }

      sourceText += ")\n"
    }

    sourceText += "  }\n  \n"
    // ==== Generate the "receive"-side, we must decode the incoming Envelope
    // into a _Message and apply it to our local actor.
    //
    // Some of this code could be pushed out into a transport implementation,
    // specifically the serialization logic does not have to live in here as
    // long as we get hold of the type we need to deserialize.
    sourceText += """
        nonisolated func _receiveAny<Encoder, Decoder>(
          envelope: Envelope, encoder: Encoder, decoder: Decoder
        ) async throws -> Encoder.Output
          where Encoder: TopLevelEncoder, Decoder: TopLevelDecoder {
          let message = try decoder.decode(_Message.self, from: envelope.message as! Decoder.Input) // TODO: this needs restructuring to avoid the cast, we need to know what types we work with
          return try await self._receive(message: message, encoder: encoder)
        }
        
        nonisolated func _receive<Encoder>(
          message: _Message, encoder: Encoder
        ) async throws -> Encoder.Output where Encoder: TopLevelEncoder {
          do {
            switch message {
      """
    
    for fun in decl.funcs {
      sourceText += "\n      case .\(fun.name)\(fun.parameterMatch):\n"
      sourceText += "        "
      
      if fun.result != "Void" {
          sourceText += "let result = "
      }

      sourceText += "try await self.\(fun.name)("


      sourceText += fun.params.map { param in
        let (label, name, _) = param
        if let label = label, label != "_" {
            return "\(label): \(name)"
        }
        return name
      }.joined(separator: ", ")

      sourceText += ")\n"

      let returnValue = fun.result == "Void" ? "Optional<String>.none" : "result"

      sourceText += "        return try encoder.encode(\(returnValue))\n"
    }

    sourceText += """
            }
          } catch {
            fatalError("Error handling not implemented; \\(error)")
          }
        }
      """
    sourceText += "\n  \n"
    sourceText += decl.funcs.map { $0.dynamicReplacementFunc }.joined(separator: "\n  \n")


    sourceText += "\n"
    sourceText += """
    }
    """

    return sourceText
  }
}

extension FuncDecl {
  var dynamicReplacementFunc: String {
    """
      @_dynamicReplacement(for: _remote_\(name)(\(prototype)))
      nonisolated func _fishy_\(name)(\(argumentList)) async throws \(funcReturn) {
        let message = Self._Message.\(name)\(messageArguments)
        return try await requireFishyTransport.send(message, to: self.id, expecting: \(result).self)
      }
    """
  }

  var funcReturn: String {
    return result != "Void" ? "-> \(result)" : ""
  }

  var prototype: String {
    params.map { param in
      let (label, name, _) = param
      var result = ""
      result += label ?? name
      result += ":"
      return result
    }.joined()
  }

  var argumentList: String {
    params.map { param in
      let (label, name, type) = param
      var result = ""

      if let label = label {
        result += label
      }

      if name != label {
        result += " \(name)"
      }

      result += ": \(type)"

      return result
    }.joined(separator: ", ")
  }

  var messageArguments: String {
    guard !params.isEmpty else {
      return ""
    }

    return "(" + params.map { param in
      let (label, name, _) = param
      if let label = label, label != "_" {
        return "\(label): \(name)"
      } else {
        return name
      }

    }.joined(separator: ", ") + ")"
  }

  var parameterMatch: String {
    guard !params.isEmpty else {
      return ""
    }

    return "(" + params.map { param in
      let (_, name, _) = param
      return "let \(name)"
    }.joined(separator: ", ") + ")"
  }
}
