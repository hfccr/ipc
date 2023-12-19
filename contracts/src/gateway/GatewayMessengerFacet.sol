// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import {GatewayActorModifiers} from "../lib/LibGatewayActorStorage.sol";
import {BURNT_FUNDS_ACTOR} from "../constants/Constants.sol";
import {CrossMsg, StorableMsg} from "../structs/Checkpoint.sol";
import {IPCMsgType} from "../enums/IPCMsgType.sol";
import {SubnetID} from "../structs/Subnet.sol";
import {InvalidCrossMsgFromSubnet, InvalidCrossMsgDstSubnet, CannotSendCrossMsgToItself, InvalidCrossMsgValue} from "../errors/IPCErrors.sol";
import {SubnetIDHelper} from "../lib/SubnetIDHelper.sol";
import {LibGateway} from "../lib/LibGateway.sol";
import {StorableMsgHelper} from "../lib/StorableMsgHelper.sol";
import {FilAddress} from "fevmate/utils/FilAddress.sol";

contract GatewayMessengerFacet is GatewayActorModifiers {
    using FilAddress for address payable;
    using SubnetIDHelper for SubnetID;
    using StorableMsgHelper for StorableMsg;

    /**
     * @dev sends an arbitrary cross-message from the local subnet to the destination subnet.
     *
     * IMPORTANT: `msg.value` is expected to equal to the value sent in `crossMsg.value` plus the cross-messaging fee.
     *
     * @param crossMsg - a cross-message to send
     */
    function sendCrossMessage(CrossMsg calldata crossMsg) external payable validFee(crossMsg.message.fee) {
        if (crossMsg.message.value != msg.value - crossMsg.message.fee) {
            revert InvalidCrossMsgValue();
        }

        // We disregard the "to" of the message that will be verified in the _commitCrossMessage().
        // The caller is the one set as the "from" of the message
        if (!crossMsg.message.from.subnetId.equals(s.networkName)) {
            revert InvalidCrossMsgFromSubnet();
        }

        // commit cross-message for propagation
        bool shouldBurn = _commitCrossMessage(crossMsg);

        _crossMsgSideEffects({v: crossMsg.message.value, shouldBurn: shouldBurn});
    }

    /**
     * @dev propagates the populated cross net message for the given cid
     * @param msgCid - the cid of the cross-net message
     */
    function propagate(bytes32 msgCid) external payable {
        CrossMsg storage crossMsg = s.postbox[msgCid];
        validateFee(crossMsg.message.fee);

        bool shouldBurn = _commitCrossMessage(crossMsg);
        // We must delete the message first to prevent potential re-entrancies,
        // and as the message is deleted and we don't have a reference to the object
        // anymore, we need to pull the data from the message to trigger the side-effects.
        uint256 v = crossMsg.message.value;
        delete s.postbox[msgCid];

        _crossMsgSideEffects({v: v, shouldBurn: shouldBurn});

        uint256 feeRemainder = msg.value - s.minCrossMsgFee;

        // gas-opt: original check: feeRemainder > 0
        if (feeRemainder != 0) {
            payable(msg.sender).sendValue(feeRemainder);
        }
    }

    /**
     * @dev Commit the cross message to storage. It outputs a flag signaling
     * if the committed messages was bottom-up and some funds need to be
     * burnt.
     *
     * It also validates that destination subnet ID is not empty
     * and not equal to the current network.
     */
    function _commitCrossMessage(CrossMsg memory crossMessage) internal returns (bool shouldBurn) {
        SubnetID memory to = crossMessage.message.to.subnetId;
        if (to.isEmpty()) {
            revert InvalidCrossMsgDstSubnet();
        }
        // destination is the current network, you are better off with a good old message, no cross needed
        if (to.equals(s.networkName)) {
            revert CannotSendCrossMsgToItself();
        }

        SubnetID memory from = crossMessage.message.from.subnetId;
        IPCMsgType applyType = crossMessage.message.applyType(s.networkName);

        // slither-disable-next-line uninitialized-local
        bool shouldCommitBottomUp;

        if (applyType == IPCMsgType.BottomUp) {
            shouldCommitBottomUp = !to.commonParent(from).equals(s.networkName);
        }

        if (shouldCommitBottomUp) {
            LibGateway.commitBottomUpMsg(crossMessage);

            // gas-opt: original check: value > 0
            return (shouldBurn = crossMessage.message.value != 0);
        }

        if (applyType == IPCMsgType.TopDown) {
            ++s.appliedTopDownNonce;
        }

        LibGateway.commitTopDownMsg(crossMessage);

        return (shouldBurn = false);
    }

    /**
     * @dev Performs transaction side-effects from the commitment of a cross-net message. Like
     * burning funds when bottom-up messages are propagated.
     *
     * @param v - the value of the committed cross-net message
     * @param shouldBurn - flag if the message should burn funds
     */
    function _crossMsgSideEffects(uint256 v, bool shouldBurn) internal {
        if (shouldBurn) {
            payable(BURNT_FUNDS_ACTOR).sendValue(v);
        }
    }
}