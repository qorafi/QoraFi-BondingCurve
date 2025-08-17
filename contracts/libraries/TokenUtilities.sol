// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

/**
 * @title TokenUtilities
 * @notice Token handling and helper utilities
 */

// --- TOKEN HELPER LIBRARY ---
library TokenHelperLib {
    using SafeERC20 for IERC20;

    // Token helper errors
    error TransferFailed();
    error InsufficientBalance();
    error InvalidToken();

    /**
     * @notice Safely transfers tokens with balance check
     * @param token Token address
     * @param from From address
     * @param to To address
     * @param amount Amount to transfer
     */
    function safeTransferWithCheck(
        address token,
        address from,
        address to,
        uint256 amount
    ) internal {
        if (token == address(0)) revert InvalidToken();
        if (amount == 0) return;

        uint256 balance = IERC20(token).balanceOf(from);
        if (balance < amount) revert InsufficientBalance();

        if (from == address(this)) {
            IERC20(token).safeTransfer(to, amount);
        } else {
            IERC20(token).safeTransferFrom(from, to, amount);
        }
    }

    /**
     * @notice Gets token balance safely
     * @param token Token address
     * @param account Account address
     * @return balance Token balance
     */
    function getBalance(address token, address account) internal view returns (uint256 balance) {
        if (token == address(0)) return 0;
        
        try IERC20(token).balanceOf(account) returns (uint256 bal) {
            return bal;
        } catch {
            return 0;
        }
    }

    /**
     * @notice Gets token allowance safely
     * @param token Token address
     * @param owner Owner address
     * @param spender Spender address
     * @return allowance Token allowance
     */
    function getAllowance(address token, address owner, address spender) internal view returns (uint256 allowance) {
        if (token == address(0)) return 0;
        
        try IERC20(token).allowance(owner, spender) returns (uint256 allow) {
            return allow;
        } catch {
            return 0;
        }
    }

    /**
     * @notice Safely resets token allowance to zero
     * @param token Token address
     * @param spender Spender address
     */
    function resetAllowance(address token, address spender) internal {
        if (token == address(0)) return;
        
        uint256 currentAllowance = getAllowance(token, address(this), spender);
        if (currentAllowance > 0) {
            IERC20(token).safeDecreaseAllowance(spender, currentAllowance);
        }
    }

    /**
     * @notice Sets exact allowance (resets first if needed)
     * @param token Token address
     * @param spender Spender address
     * @param amount Allowance amount
     */
    function setExactAllowance(address token, address spender, uint256 amount) internal {
        resetAllowance(token, spender);
        if (amount > 0) {
            IERC20(token).safeIncreaseAllowance(spender, amount);
        }
    }

    /**
     * @notice Gets token decimals safely
     * @param token Token address
     * @return decimals Token decimals (default 18 if not found)
     */
    function getDecimals(address token) internal view returns (uint8 decimals) {
        if (token == address(0)) return 18;
        
        try IERC20Metadata(token).decimals() returns (uint8 dec) {
            return dec;
        } catch {
            return 18;
        }
    }

    /**
     * @notice Gets token symbol safely
     * @param token Token address
     * @return symbol Token symbol
     */
    function getSymbol(address token) internal view returns (string memory symbol) {
        if (token == address(0)) return "ETH";
        
        try IERC20Metadata(token).symbol() returns (string memory sym) {
            return sym;
        } catch {
            return "UNKNOWN";
        }
    }

    /**
     * @notice Gets token name safely
     * @param token Token address
     * @return name Token name
     */
    function getName(address token) internal view returns (string memory name) {
        if (token == address(0)) return "Ether";
        
        try IERC20Metadata(token).name() returns (string memory tokenName) {
            return tokenName;
        } catch {
            return "Unknown Token";
        }
    }

    /**
     * @notice Converts token amount between different decimal places
     * @param amount Amount to convert
     * @param fromDecimals Source decimals
     * @param toDecimals Target decimals
     * @return convertedAmount Converted amount
     */
    function convertDecimals(
        uint256 amount,
        uint8 fromDecimals,
        uint8 toDecimals
    ) internal pure returns (uint256 convertedAmount) {
        if (fromDecimals == toDecimals) {
            return amount;
        } else if (fromDecimals > toDecimals) {
            return amount / (10 ** (fromDecimals - toDecimals));
        } else {
            return amount * (10 ** (toDecimals - fromDecimals));
        }
    }

    /**
     * @notice Formats token amount for display
     * @param token Token address
     * @param amount Raw token amount
     * @param displayDecimals Number of decimals to display
     * @return formattedAmount Formatted amount as string
     */
    function formatTokenAmount(
        address token,
        uint256 amount,
        uint8 displayDecimals
    ) internal view returns (string memory formattedAmount) {
        uint8 tokenDecimals = getDecimals(token);
        
        if (tokenDecimals <= displayDecimals) {
            return _uint2str(amount);
        }
        
        uint256 divisor = 10 ** (tokenDecimals - displayDecimals);
        uint256 wholePart = amount / divisor;
        
        return _uint2str(wholePart);
    }

    /**
     * @notice Internal function to convert uint to string
     */
    function _uint2str(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) {
            return "0";
        }
        uint256 j = _i;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(_i - _i / 10 * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }

    /**
     * @notice Validates if token exists and is a valid ERC20
     * @param token Token address to validate
     * @return isValid Whether token is valid
     */
    function isValidERC20(address token) internal view returns (bool isValid) {
        if (token == address(0)) return false;
        
        try IERC20(token).totalSupply() returns (uint256) {
            return true;
        } catch {
            return false;
        }
    }

    /**
     * @notice Gets comprehensive token info
     * @param token Token address
     * @return name Token name
     * @return symbol Token symbol
     * @return decimals Token decimals
     * @return totalSupply Total supply
     */
    function getTokenInfo(address token) internal view returns (
        string memory name,
        string memory symbol,
        uint8 decimals,
        uint256 totalSupply
    ) {
        name = getName(token);
        symbol = getSymbol(token);
        decimals = getDecimals(token);
        
        try IERC20(token).totalSupply() returns (uint256 supply) {
            totalSupply = supply;
        } catch {
            totalSupply = 0;
        }
    }

    /**
     * @notice Batch gets balances for multiple tokens
     * @param tokens Array of token addresses
     * @param account Account to check
     * @return balances Array of balances
     */
    function batchGetBalances(
        address[] memory tokens,
        address account
    ) internal view returns (uint256[] memory balances) {
        balances = new uint256[](tokens.length);
        
        for (uint256 i = 0; i < tokens.length; i++) {
            balances[i] = getBalance(tokens[i], account);
        }
    }

    /**
     * @notice Batch transfers multiple tokens
     * @param tokens Array of token addresses
     * @param amounts Array of amounts
     * @param to Recipient address
     */
    function batchTransfer(
        address[] memory tokens,
        uint256[] memory amounts,
        address to
    ) internal {
        require(tokens.length == amounts.length, "Array length mismatch");
        
        for (uint256 i = 0; i < tokens.length; i++) {
            if (amounts[i] > 0) {
                safeTransferWithCheck(tokens[i], address(this), to, amounts[i]);
            }
        }
    }
}

// --- LEDGER INTEGRATION LIBRARY ---
library LedgerLib {
    // Ledger errors
    error LedgerNotificationFailed();
    error InvalidLedgerAddress();

    /**
     * @notice Safely notifies ledger with error handling
     * @param ledger Ledger contract address
     * @param user User address
     * @param amount Transaction amount
     * @return success Whether notification was successful
     * @return errorReason Error reason if failed
     */
    function safeNotifyLedger(
        address ledger,
        address user,
        uint256 amount
    ) internal returns (bool success, string memory errorReason) {
        if (ledger == address(0)) {
            return (false, "Invalid ledger address");
        }

        // Use low-level call to avoid import dependency
        (bool callSuccess, bytes memory returnData) = ledger.call(
            abi.encodeWithSignature("notifyDeposit(address,uint256)", user, amount)
        );
        
        if (callSuccess) {
            return (true, "");
        } else {
            // Decode revert reason if available
            if (returnData.length > 0) {
                // Try to decode the revert reason
                if (returnData.length >= 68) {
                    assembly {
                        returnData := add(returnData, 0x04)
                    }
                    return (false, abi.decode(returnData, (string)));
                } else {
                    return (false, "Call failed");
                }
            } else {
                return (false, "Call failed");
            }
        }
    }

    /**
     * @notice Batch notify ledger for multiple transactions
     * @param ledger Ledger contract address
     * @param users Array of user addresses
     * @param amounts Array of amounts
     * @return successCount Number of successful notifications
     */
    function batchNotifyLedger(
        address ledger,
        address[] memory users,
        uint256[] memory amounts
    ) internal returns (uint256 successCount) {
        require(users.length == amounts.length, "Array length mismatch");
        
        for (uint256 i = 0; i < users.length; i++) {
            (bool success, ) = safeNotifyLedger(ledger, users[i], amounts[i]);
            if (success) {
                successCount++;
            }
        }
    }

    /**
     * @notice Validates ledger contract interface
     * @param ledger Ledger contract address
     * @return isValid Whether ledger implements required interface
     */
    function validateLedgerInterface(address ledger) internal returns (bool isValid) {
        if (ledger == address(0)) return false;
        
        // Use low-level call to check interface
        (bool success, ) = ledger.call(
            abi.encodeWithSignature("notifyDeposit(address,uint256)", address(0), 0)
        );
        return success;
    }
}

// --- INTERFACES ---
interface IERC20Metadata {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

/**
 * @title TokenUtilities Contract
 */
contract TokenUtilities {
    using SafeERC20 for IERC20;
    
    function getLibraryVersion() external pure returns (string memory) {
        return "TOKEN-1.0.0";
    }
    
    // Token helper functions for testing
    function getTokenBalance(address token, address account) external view returns (uint256) {
        return TokenHelperLib.getBalance(token, account);
    }
    
    function getTokenDecimals(address token) external view returns (uint8) {
        return TokenHelperLib.getDecimals(token);
    }
    
    function getTokenSymbol(address token) external view returns (string memory) {
        return TokenHelperLib.getSymbol(token);
    }
    
    function getTokenName(address token) external view returns (string memory) {
        return TokenHelperLib.getName(token);
    }
    
    function convertTokenDecimals(
        uint256 amount,
        uint8 fromDecimals,
        uint8 toDecimals
    ) external pure returns (uint256) {
        return TokenHelperLib.convertDecimals(amount, fromDecimals, toDecimals);
    }
    
    function isValidERC20(address token) external view returns (bool) {
        return TokenHelperLib.isValidERC20(token);
    }
    
    function getTokenInfo(address token) external view returns (
        string memory name,
        string memory symbol,
        uint8 decimals,
        uint256 totalSupply
    ) {
        return TokenHelperLib.getTokenInfo(token);
    }
    
    function batchGetBalances(
        address[] memory tokens,
        address account
    ) external view returns (uint256[] memory balances) {
        return TokenHelperLib.batchGetBalances(tokens, account);
    }
    
    // Ledger functions for testing
    function safeNotifyLedger(
        address ledger,
        address user,
        uint256 amount
    ) external returns (bool success, string memory errorReason) {
        return LedgerLib.safeNotifyLedger(ledger, user, amount);
    }
    
    function validateLedgerInterface(address ledger) external returns (bool) {
        return LedgerLib.validateLedgerInterface(ledger);
    }
}