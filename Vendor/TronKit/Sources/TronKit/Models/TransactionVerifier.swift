import Foundation

/// Checks the protobuf bytes that will be signed, rather than trusting the node's JSON view.
/// Uses TronKit's existing generated protobuf types; callers never handle those internal types.
public enum TransactionVerifier {
    public static func matchesTriggerSmartContract(
        rawData: Data, owner: Address, contract: Address, callData: Data, feeLimit: Int64
    ) -> Bool {
        guard let raw = try? Protocol_Transaction.raw(serializedBytes: rawData),
              raw.contract.count == 1,
              let item = raw.contract.first,
              item.type == .triggerSmartContract,
              item.parameter.typeURL == "type.googleapis.com/protocol.TriggerSmartContract",
              let trigger = try? Protocol_TriggerSmartContract(serializedBytes: item.parameter.value),
              trigger.ownerAddress == owner.raw,
              trigger.contractAddress == contract.raw,
              trigger.data == callData,
              trigger.callValue == 0,
              trigger.callTokenValue == 0,
              trigger.tokenID == 0,
              raw.feeLimit == feeLimit,
              raw.auths.isEmpty, raw.data.isEmpty, raw.scripts.isEmpty,
              item.provider.isEmpty, item.contractName.isEmpty, item.permissionID == 0,
              raw.unknownFields.data.isEmpty,
              item.unknownFields.data.isEmpty,
              trigger.unknownFields.data.isEmpty else { return false }
        return true
    }
}
