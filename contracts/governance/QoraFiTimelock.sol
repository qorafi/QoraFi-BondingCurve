// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title QoraFiTimelock
 * @dev The Timelock contract that owns the protocol and executes proposals from the Governor.
 * @notice This contract is designed to have no admin after deployment for maximum decentralization.
 */
contract QoraFiTimelock is TimelockController {
    
    // --- CONSTANTS ---
    uint256 public constant MIN_DELAY = 24 hours;
    uint256 public constant MAX_DELAY = 30 days;

    // --- EVENTS ---
    event TimelockDeployed(uint256 minDelay, address[] proposers, address[] executors);

    // --- ERRORS ---
    error InvalidDelay();
    error NoProposers();
    error DelayTooLong();
    error InvalidProposer();
    error InvalidExecutorConfig();

    /**
     * @param minDelay Minimum delay in seconds before execution (24h - 30 days).
     * @param proposers Array of addresses allowed to propose (typically the Governor contract).
     * @param executors Array of addresses allowed to execute (use [address(0)] for public execution).
     */
    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors
    ) TimelockController(minDelay, proposers, executors, address(0)) { // admin set to address(0) for no admin
        if (minDelay < MIN_DELAY) revert InvalidDelay();
        if (minDelay > MAX_DELAY) revert DelayTooLong();
        if (proposers.length == 0) revert NoProposers();

        // Validate proposer addresses to prevent misconfiguration
        for (uint i = 0; i < proposers.length; ++i) {
            if (proposers[i] == address(0)) revert InvalidProposer();
        }

        // Optional: validate non-zero executors if that's your requirement
        for (uint i = 0; i < executors.length; ++i) {
            // A mix of zero and non-zero executors might be unintentional
            if (executors[i] == address(0) && executors.length > 1) {
                revert InvalidExecutorConfig();
            }
        }

        emit TimelockDeployed(minDelay, proposers, executors);
    }
}