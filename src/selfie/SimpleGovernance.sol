// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {DamnValuableVotes} from "../DamnValuableVotes.sol";
import {ISimpleGovernance} from "./ISimpleGovernance.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

contract SimpleGovernance is ISimpleGovernance {
    using Address for address;

    uint256 private constant ACTION_DELAY_IN_SECONDS = 2 days;

    DamnValuableVotes private _votingToken;
    uint256 private _actionCounter;
    mapping(uint256 => GovernanceAction) private _actions;

    constructor(DamnValuableVotes votingToken) {
        _votingToken = votingToken;
        _actionCounter = 1;
    }

    function queueAction(address target, uint128 value, bytes calldata data) external returns (uint256 actionId) {
        // more than 50%
        // @audit inherits ERC20Votes
        // using flashloan to get more than 50% of power [_receiver.onFlashLoan(msg.sender, _token, _amount, 0, _data)]
        // then call queueAction function followed by executeAction function
        // call emergencyExit function and loot the pool 
        if (!_hasEnoughVotes(msg.sender)) {
            revert NotEnoughVotes(msg.sender);
        }
        // cannot call function of this contract 
        if (target == address(this)) {
            revert InvalidTarget();
        }

        if (data.length > 0 && target.code.length == 0) {
            revert TargetMustHaveCode();
        }

        actionId = _actionCounter;

        _actions[actionId] = GovernanceAction({
            target: target,
            value: value,
            proposedAt: uint64(block.timestamp),
            executedAt: 0,
            data: data
        });

        unchecked {
            _actionCounter++;
        }

        emit ActionQueued(actionId, msg.sender);
    }

    // condition: created and not executed, time limit should have passed
    function executeAction(uint256 actionId) external payable returns (bytes memory) {
        if (!_canBeExecuted(actionId)) {
            revert CannotExecute(actionId);
        }

        GovernanceAction storage actionToExecute = _actions[actionId];
        actionToExecute.executedAt = uint64(block.timestamp);

        emit ActionExecuted(actionId, msg.sender);
        // we have to this, target is selfie pool and data is emergencyExit, value is recovery address 
        return actionToExecute.target.functionCallWithValue(actionToExecute.data, actionToExecute.value);
    }

    function getActionDelay() external pure returns (uint256) {
        return ACTION_DELAY_IN_SECONDS;
    }

    function getVotingToken() external view returns (address) {
        return address(_votingToken);
    }

    function getAction(uint256 actionId) external view returns (GovernanceAction memory) {
        return _actions[actionId];
    }

    function getActionCounter() external view returns (uint256) {
        return _actionCounter;
    }

    /**
     * @dev an action can only be executed if:
     * 1) it's never been executed before and
     * 2) enough time has passed since it was first proposed
     */
    function _canBeExecuted(uint256 actionId) private view returns (bool) {
        GovernanceAction memory actionToExecute = _actions[actionId];

        if (actionToExecute.proposedAt == 0) return false;

        uint64 timeDelta;
        unchecked {
            timeDelta = uint64(block.timestamp) - actionToExecute.proposedAt;
        }

        // not been executed before, time limit has passed
        return actionToExecute.executedAt == 0 && timeDelta >= ACTION_DELAY_IN_SECONDS;
    }

    // requirement is more than 50% of the voting power
    function _hasEnoughVotes(address who) private view returns (bool) {
        uint256 balance = _votingToken.getVotes(who);
        uint256 halfTotalSupply = _votingToken.totalSupply() / 2;
        return balance > halfTotalSupply;
    }
}
