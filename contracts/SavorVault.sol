// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

//import {Auth} from "./Solmate/auth/Auth.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import {Savor4626} from "./Savor4626.sol";

import {SafeCastLib} from "./Solmate/utils/SafeCastLib.sol";
import {SafeTransferLib} from "./Solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "./Solmate/utils/FixedPointMathLib.sol";

import {WETH} from "./Solmate/tokens/WETH.sol";
import {ERC20} from "./Solmate/tokens/ERC20.sol";

import {Strategy} from "./Interfaces/IStrategy.sol";
import {IBridgerton} from "./Interfaces/IBridgerton.sol";

contract SavorVault is Savor4626, Ownable {
    using SafeCastLib for uint256;
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    /*///////////////////////////////////////////////////////////////
                                 CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice The maximum number of elements allowed on the withdrawal stack.
    /// @dev Needed to prevent denial of service attacks by queue operators.
    uint256 internal constant MAX_WITHDRAWAL_STACK_SIZE = 32;

    /*///////////////////////////////////////////////////////////////
                                IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The underlying token the Vault accepts.
    ERC20 public immutable UNDERLYING;

    /// @notice The base unit of the underlying token and hence rvToken.
    /// @dev Equal to 10 ** decimals. Used for fixed point arithmetic.
    uint256 internal immutable BASE_UNIT;

    /// @notice Creates a new Vault that accepts a specific underlying token.
    /// @param _UNDERLYING The ERC20 compliant token the Vault should accept.
    /// @param _keeper The address to set ass keeper
    constructor(
        ERC20 _UNDERLYING,
        address _bridgerton,
        address _keeper
    )
        Savor4626(
            // Underlying token
            _UNDERLYING,
            // ex: Savor Dai Stablecoin Vault
            string(abi.encodePacked("Savor ", _UNDERLYING.name(), " Vault")),
            // ex: svDAI
            string(abi.encodePacked("sv", _UNDERLYING.symbol()))
        )
    {
        UNDERLYING = _UNDERLYING;

        BASE_UNIT = 10**decimals;

        Bridgerton = IBridgerton(_bridgerton);
        keeper = _keeper;

        // Prevent minting of rvTokens until
        // the initialize function is called.
        totalSupply = type(uint256).max;
    }

    /*///////////////////////////////////////////////////////////////
                           FEE CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice The percentage of profit recognized each harvest to reserve as fees.
    /// @dev A fixed point number where 1e18 represents 100% and 0 represents 0%.
    uint256 public feePercent;

    /// @notice Emitted when the fee percentage is updated.
    /// @param user The authorized user who triggered the update.
    /// @param newFeePercent The new fee percentage.
    event FeePercentUpdated(address indexed user, uint256 newFeePercent);

    /// @notice Sets a new fee percentage.
    /// @param newFeePercent The new fee percentage.
    function setFeePercent(uint256 newFeePercent) external onlyOwner {
        // A fee percentage over 100% doesn't make sense.
        require(newFeePercent <= 1e18, "FEE_TOO_HIGH");

        // Update the fee percentage.
        feePercent = newFeePercent;

        emit FeePercentUpdated(msg.sender, newFeePercent);
    }

    /*///////////////////////////////////////////////////////////////
                        HARVEST CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the keeper is updated.
    /// @param _keeper The new keeper after the update.
    event KeeperUpdated(address _keeper);

    /// @notice Emitted when the harvest window is updated.
    /// @param user The authorized user who triggered the update.
    /// @param newHarvestWindow The new harvest window.
    event HarvestWindowUpdated(address indexed user, uint128 newHarvestWindow);

    /// @notice Emitted when the harvest delay is updated.
    /// @param user The authorized user who triggered the update.
    /// @param newHarvestDelay The new harvest delay.
    event HarvestDelayUpdated(address indexed user, uint64 newHarvestDelay);

    /// @notice Emitted when the harvest delay is scheduled to be updated next harvest.
    /// @param user The authorized user who triggered the update.
    /// @param newHarvestDelay The scheduled updated harvest delay.
    event HarvestDelayUpdateScheduled(
        address indexed user,
        uint64 newHarvestDelay
    );

    /// @notice The period in seconds during which multiple harvests can occur
    /// regardless if they are taking place before the harvest delay has elapsed.
    /// @dev Long harvest windows open the Vault up to profit distribution slowdown attacks.
    uint128 public harvestWindow;

    /// @notice The period in seconds over which locked profit is unlocked.
    /// @dev Cannot be 0 as it opens harvests up to sandwich attacks.
    uint64 public harvestDelay;

    /// @notice The value that will replace harvestDelay next harvest.
    /// @dev In the case that the next delay is 0, no update will be applied.
    uint64 public nextHarvestDelay;

    /// @notice The address of the current keeper.
    /// @dev gets set in constructor. Default is msg.sender
    address public keeper;

    /// @notice To be called on contracts where a keeper is allowed
    /// @dev Keeps onlyOwner to be for onlyOwner Calls.
    modifier onlyKeeper() {
        require(msg.sender == owner() || msg.sender == keeper, "UNAUTHORIZED");
        _;
    }

    /// @notice Sets a new keeper.
    /// @param _newKeeper The new keeper address.
    /// @dev Must be called by either owner or current keeper.
    function setNewKeeper(address _newKeeper) external onlyKeeper {
        require(_newKeeper != address(0), "Invalid Address");

        // Update the keeper.
        keeper = _newKeeper;

        emit KeeperUpdated(keeper);
    }

    /// @notice Sets a new harvest window.
    /// @param newHarvestWindow The new harvest window.
    /// @dev The Vault's harvestDelay must already be set before calling.
    function setHarvestWindow(uint128 newHarvestWindow) external onlyOwner {
        // A harvest window longer than the harvest delay doesn't make sense.
        require(newHarvestWindow <= harvestDelay, "WINDOW_TOO_LONG");

        // Update the harvest window.
        harvestWindow = newHarvestWindow;

        emit HarvestWindowUpdated(msg.sender, newHarvestWindow);
    }

    /// @notice Sets a new harvest delay.
    /// @param newHarvestDelay The new harvest delay to set.
    /// @dev If the current harvest delay is 0, meaning it has not
    /// been set before, it will be updated immediately, otherwise
    /// it will be scheduled to take effect after the next harvest.
    function setHarvestDelay(uint64 newHarvestDelay) external onlyOwner {
        // A harvest delay of 0 makes harvests vulnerable to sandwich attacks.
        require(newHarvestDelay != 0, "DELAY_CANNOT_BE_ZERO");

        // A harvest delay longer than 1 year doesn't make sense.
        require(newHarvestDelay <= 365 days, "DELAY_TOO_LONG");

        // If the harvest delay is 0, meaning it has not been set before:
        if (harvestDelay == 0) {
            // We'll apply the update immediately.
            harvestDelay = newHarvestDelay;

            emit HarvestDelayUpdated(msg.sender, newHarvestDelay);
        } else {
            // We'll apply the update next harvest.
            nextHarvestDelay = newHarvestDelay;

            emit HarvestDelayUpdateScheduled(msg.sender, newHarvestDelay);
        }
    }

    /*///////////////////////////////////////////////////////////////
                       TARGET FLOAT CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice The desired percentage of the Vault's holdings to keep as float.
    /// @dev A fixed point number where 1e18 represents 100% and 0 represents 0%.
    uint256 public targetFloatPercent;

    /// @notice Emitted when the target float percentage is updated.
    /// @param user The authorized user who triggered the update.
    /// @param newTargetFloatPercent The new target float percentage.
    event TargetFloatPercentUpdated(
        address indexed user,
        uint256 newTargetFloatPercent
    );

    /// @notice Set a new target float percentage.
    /// @param newTargetFloatPercent The new target float percentage.
    function setTargetFloatPercent(uint256 newTargetFloatPercent)
        external
        onlyOwner
    {
        // A target float percentage over 100% doesn't make sense.
        require(newTargetFloatPercent <= 1e18, "TARGET_TOO_HIGH");

        // Update the target float percentage.
        targetFloatPercent = newTargetFloatPercent;

        emit TargetFloatPercentUpdated(msg.sender, newTargetFloatPercent);
    }

    /*///////////////////////////////////////////////////////////////
                          STRATEGY STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The total amount of underlying tokens held in strategies at the time of the last harvest.
    /// @dev Includes maxLockedProfit, must be correctly subtracted to compute available/free holdings.
    uint256 public totalStrategyHoldings;

    /// @dev Packed struct of strategy data.
    /// @param trusted Whether the strategy is trusted.
    /// @param balance The amount of underlying tokens held in the strategy.
    struct StrategyData {
        // Used to determine if the Vault will operate on a strategy.
        bool trusted;
        // Used to determine profit and loss during harvests of the strategy.
        uint248 balance;
    }

    /// @notice Maps strategies to data the Vault holds on them.
    mapping(Strategy => StrategyData) public getStrategyData;

    /*///////////////////////////////////////////////////////////////
                             HARVEST STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice A timestamp representing when the first harvest in the most recent harvest window occurred.
    /// @dev May be equal to lastHarvest if there was/has only been one harvest in the most last/current window.
    uint64 public lastHarvestWindowStart;

    /// @notice A timestamp representing when the most recent harvest occurred.
    uint64 public lastHarvest;

    /// @notice The amount of locked profit at the end of the last harvest.
    uint128 public maxLockedProfit;

    /*///////////////////////////////////////////////////////////////
                        WITHDRAWAL STACK STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice An ordered array of strategies representing the withdrawal stack.
    /// @dev The stack is processed in descending order, meaning the last index will be withdrawn from first.
    /// @dev Strategies that are untrusted, duplicated, or have no balance are filtered out when encountered at
    /// withdrawal time, not validated upfront, meaning the stack may not reflect the "true" set used for withdrawals.
    Strategy[] public withdrawalStack;

    /// @notice Gets the full withdrawal stack.
    /// @return An ordered array of strategies representing the withdrawal stack.
    /// @dev This is provided because Solidity converts public arrays into index getters,
    /// but we need a way to allow external contracts and users to access the whole array.
    function getWithdrawalStack() external view returns (Strategy[] memory) {
        return withdrawalStack;
    }

    /*///////////////////////////////////////////////////////////////
                        Bridgerton LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice the instance of the current Bridgerton contract we will use
    IBridgerton Bridgerton;

    /// @notice Emitted when the Funds are received by this contract from Stargate router.
    /// @param _chainId The chain from which the funds were sent.
    /// @param _srcAddress The address the sent the transaction. Should be the same as address(this).
    /// @param _token Address of the token that was received. Should Be UNDERLYING
    /// @param amountLD Amount of token received
    event sgReceived(
        uint16 _chainId,
        bytes _srcAddress,
        address _token,
        uint256 amountLD
    );

    function setBridgerton(address _bridgerton) external onlyOwner {
        Bridgerton = IBridgerton(_bridgerton);
    }

    /// @notice Function to be called by keeper to initiate a cross chain swap
    /// @dev The function will transfer funds from the vault to Bridgerton to minimize gas usage for Bridgerton
    ///         so that the gas estimate check is accurate
    ///       Sends the full gas value in this contract and any extra is refunded to the tx.origin.
    /// @param chainId The id of chain we are swapping to
    /// @param _amount The amount of underlying to swap
    /// @param _vaultTo The strategy the receving vault should deposit in if applicable
    function swap(
        uint16 chainId,
        uint256 _amount,
        address _vaultTo
    ) external payable onlyKeeper {
        require(
            UNDERLYING.balanceOf(address(this)) >= _amount,
            "Not enough funds for that swap"
        );

        UNDERLYING.safeTransfer(address(Bridgerton), _amount);

        Bridgerton.swap{value: address(this).balance}(
            chainId,
            address(UNDERLYING),
            _amount,
            _vaultTo
        );
    }

    /// @notice function for the stargate router to call when funds are being received from another chain
    /// @param _chainId Chain from which the assets came
    /// @param _srcAddress Address who initiated the transfer. Should be address(this)
    /// @param _nonce Nonce the transaction occured on
    /// @param _token Address of token that was transferred. Should be UNDERLYING
    /// @param amountLD The amount that was received
    /// @param payload Encoded payload with any instructions sent over
    function sgReceive(
        uint16 _chainId,
        bytes memory _srcAddress,
        uint256 _nonce,
        address _token,
        uint256 amountLD,
        bytes memory payload
    ) external {
        emit sgReceived(_chainId, _srcAddress, _token, amountLD);
    }

    /*///////////////////////////////////////////////////////////////
                        DEPOSIT/WITHDRAWAL LOGIC
    //////////////////////////////////////////////////////////////*/

    function afterDeposit(uint256, uint256) internal override {}

    /// @notice Called after the withdraw/redeem functions are called
    /// @dev Checks if we hae enouogh funds on this chain for withdraw. If not updates the pending withdraws that will be payed out on next harvest
    /// @param assets The amount in Underlying trying to be withdrawn
    /// @param receiver Address of the user trying to withdrawl
    /// @return isAllAvailable Returns true if enough funds false if not
    /// @return amountAvailable The amount available to be withdrawn. Only used if isAllAvailable is false
    function beforeWithdraw(uint256 assets, address receiver)
        internal
        override
        returns (bool isAllAvailable, uint256 amountAvailable)
    {
        //check available funds on this chain
        amountAvailable = thisVaultsHoldings();

        //if not enough remove what we can
        if (assets > amountAvailable) {
            isAllAvailable = false;
            //We can have the same owner multiple times in the array because all mapped values will be reduced after payout
            waitingOnWithdrawals.push(receiver);

            if (amountAvailable > 0) {
                retrieveUnderlying(amountAvailable);
            }

            //How much in shares that we will need to send on Harvest
            //Using shares so that the user will continue to make interest
            uint256 sharesNeeded = convertToShares(assets - amountAvailable);

            // Update the shares pending for the user to be sent on Harvest()
            sharesPending[receiver] += sharesNeeded;

            //Update the total pending withdrawals for Keeper
            pendingWithdrawals += sharesNeeded;
        } else {
            // Retrieve underlying tokens from strategies/float.
            isAllAvailable = true;
            retrieveUnderlying(assets);
        }
    }

    /// @dev Retrieves a specific amount of underlying tokens held in strategies and/or float.
    /// @dev Only withdraws from strategies if needed and maintains the target float percentage if possible.
    /// @param underlyingAmount The amount of underlying tokens to retrieve.
    function retrieveUnderlying(uint256 underlyingAmount) internal {
        // Get the Vault's floating balance.
        uint256 float = totalFloat();

        // If the amount is greater than the float, withdraw from strategies.
        if (underlyingAmount > float) {
            // Compute the amount needed to reach our target float percentage.
            uint256 floatMissingForTarget = (totalAssets() - underlyingAmount)
                .mulWadDown(targetFloatPercent);

            // Compute the bare minimum amount we need for this withdrawal.
            uint256 floatMissingForWithdrawal = underlyingAmount - float;

            // Pull enough to cover the withdrawal and reach our target float percentage.
            pullFromWithdrawalStack(
                floatMissingForWithdrawal + floatMissingForTarget
            );
        }
    }

    /*///////////////////////////////////////////////////////////////
                        VAULT ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the total Supply of tokens on this chain
    /// @return total outstanding supply plus the already burned shares that have yet to be payed out
    function thisVaultsSupply() public view returns (uint256) {
        return totalSupply + pendingWithdrawals;
    }

    /// @notice Returns the total supply from the vaults on other chains
    function otherVaultsSupply() public view returns (uint256) {}

    /// @notice Returns the total supply of all the chains in order to properly calculate PPS
    /// @return Total shares from each vault on each chain
    function _totalSupply() public view override returns(uint256) {
        /*
        uint256 _thisVaultsSupply = thisVaultsSupply();

        uint256 _otherVaultsSupply = otherVaultsSupply();

        return _thisVaultsSupply + _otherVaultsSupply;
        */
        return thisVaultsSupply();
    }

    /// @notice Returns the total amount of Underlying held by the Vault on this chain
    /// @return underlyingHeld The amount this vault has access to
    function thisVaultsHoldings() public view returns (uint256 underlyingHeld) {
        unchecked {
            // Cannot underflow as locked profit can't exceed total strategy holdings.
            underlyingHeld = totalStrategyHoldings - lockedProfit();
        }

        // Include our floating balance in the total.
        underlyingHeld += totalFloat();
    }

    /// @notice Returns the total amount of underlying the vaults on other chains hold
    function otherVaultsHoldings() public view returns (uint256) {}

    /// @notice Calculates the total amount of underlying tokens the Vault holds accross chains.
    /// @return The total amount of underlying tokens the Vault holds accross chains.
    function totalAssets()
        public
        view
        override
        returns (uint256)
    {
        /*
        uint256 _thisVaultsHoldings = thisVaultsHoldings();

        uint256 _otherVaultsHoldings = otherVaultsHoldings();

        return _thisVaultsHoldings + _otherVaultsHoldings;
        */
        return thisVaultsHoldings();
    }

    /// @notice Calculates the current amount of locked profit.
    /// @return The current amount of locked profit.
    function lockedProfit() public view returns (uint256) {
        // Get the last harvest and harvest delay.
        uint256 previousHarvest = lastHarvest;
        uint256 harvestInterval = harvestDelay;

        unchecked {
            // If the harvest delay has passed, there is no locked profit.
            // Cannot overflow on human timescales since harvestInterval is capped.
            if (block.timestamp >= previousHarvest + harvestInterval) return 0;

            // Get the maximum amount we could return.
            uint256 maximumLockedProfit = maxLockedProfit;

            // Compute how much profit remains locked based on the last harvest and harvest delay.
            // It's impossible for the previous harvest to be in the future, so this will never underflow.
            return
                maximumLockedProfit -
                (maximumLockedProfit * (block.timestamp - previousHarvest)) /
                harvestInterval;
        }
    }

    /// @notice Returns the amount of underlying tokens that idly sit in the Vault.
    /// @return The amount of underlying tokens that sit idly in the Vault.
    function totalFloat() public view returns (uint256) {
        return UNDERLYING.balanceOf(address(this));
    }

    /*///////////////////////////////////////////////////////////////
                             HARVEST LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted after a successful harvest.
    /// @param user The authorized user who triggered the harvest.
    /// @param strategies The trusted strategies that were harvested.
    event Harvest(address indexed user, Strategy[] strategies);

    /// @notice To be called by keeper based on total supply / total assets for vaults on all chain
    /// @param _virtualPrice the new virtual price in 1e18
    function updateVirtualPrice(uint256 _virtualPrice) external onlyKeeper{
        virtualPrice = _virtualPrice;
    }

    /// @notice Called during the harvesting proccess once funds are received from another chain
    /// Pays out all pending withdrawals since last harvest
    function payPendingWithdraws() internal {
        if (pendingWithdrawals == 0) {
            return;
        }

        require(
            UNDERLYING.balanceOf(address(this)) >=
                convertToAssets(pendingWithdrawals)
        );

        address _currentAddress;
        uint256 _amount;
        for (uint256 i = 0; i < waitingOnWithdrawals.length; i++) {
            _currentAddress = waitingOnWithdrawals[i];
            _amount = sharesPending[_currentAddress];
            if (_amount > 0) {
                UNDERLYING.safeTransfer(_currentAddress, _amount);
            }

            sharesPending[_currentAddress] = 0;
        }

        //Reset the queue
        pendingWithdrawals = 0;
        delete waitingOnWithdrawals;
    }

    /// @notice Harvest a set of trusted strategies.
    /// @param strategies The trusted strategies to harvest.
    /// @dev Will always revert if called outside of an active
    /// harvest window or before the harvest delay has passed.
    function harvest(Strategy[] calldata strategies) external onlyOwner {
        // If this is the first harvest after the last window:
        if (block.timestamp >= lastHarvest + harvestDelay) {
            // Set the harvest window's start timestamp.
            // Cannot overflow 64 bits on human timescales.
            lastHarvestWindowStart = uint64(block.timestamp);
        } else {
            // We know this harvest is not the first in the window so we need to ensure it's within it.
            require(
                block.timestamp <= lastHarvestWindowStart + harvestWindow,
                "BAD_HARVEST_TIME"
            );
        }

        // Get the Vault's current total strategy holdings.
        uint256 oldTotalStrategyHoldings = totalStrategyHoldings;

        // Used to store the total profit accrued by the strategies.
        uint256 totalProfitAccrued;

        // Used to store the new total strategy holdings after harvesting.
        uint256 newTotalStrategyHoldings = oldTotalStrategyHoldings;

        // Will revert if any of the specified strategies are untrusted.
        for (uint256 i = 0; i < strategies.length; i++) {
            // Get the strategy at the current index.
            Strategy strategy = strategies[i];

            // If an untrusted strategy could be harvested a malicious user could use
            // a fake strategy that over-reports holdings to manipulate the exchange rate.
            require(getStrategyData[strategy].trusted, "UNTRUSTED_STRATEGY");

            // Get the strategy's previous and current balance.
            uint256 balanceLastHarvest = getStrategyData[strategy].balance;
            //This neeeds to be adjusted to avoid manipulation
            uint256 balanceThisHarvest = strategy.estimatedTotalAssets();

            // Update the strategy's stored balance. Cast overflow is unrealistic.
            getStrategyData[strategy].balance = balanceThisHarvest
                .safeCastTo248();

            // Increase/decrease newTotalStrategyHoldings based on the profit/loss registered.
            // We cannot wrap the subtraction in parenthesis as it would underflow if the strategy had a loss.
            newTotalStrategyHoldings =
                newTotalStrategyHoldings +
                balanceThisHarvest -
                balanceLastHarvest;

            unchecked {
                // Update the total profit accrued while counting losses as zero profit.
                // Cannot overflow as we already increased total holdings without reverting.
                totalProfitAccrued += balanceThisHarvest > balanceLastHarvest
                    ? balanceThisHarvest - balanceLastHarvest // Profits since last harvest.
                    : 0; // If the strategy registered a net loss we don't have any new profit.
            }
        }

        // Compute fees as the fee percent multiplied by the profit.
        uint256 feesAccrued = totalProfitAccrued.mulDivDown(feePercent, 1e18);

        // If we accrued any fees, mint an equivalent amount of rvTokens.
        // Authorized users can claim the newly minted rvTokens via claimFees.
        _mint(
            address(this),
            feesAccrued.mulDivDown(BASE_UNIT, convertToAssets(BASE_UNIT))
        );

        // Update max unlocked profit based on any remaining locked profit plus new profit.
        maxLockedProfit = (lockedProfit() + totalProfitAccrued - feesAccrued)
            .safeCastTo128();

        // Set strategy holdings to our new total.
        totalStrategyHoldings = newTotalStrategyHoldings;

        // Update the last harvest timestamp.
        // Cannot overflow on human timescales.
        lastHarvest = uint64(block.timestamp);

        emit Harvest(msg.sender, strategies);

        // Get the next harvest delay.
        uint64 newHarvestDelay = nextHarvestDelay;

        // If the next harvest delay is not 0:
        if (newHarvestDelay != 0) {
            // Update the harvest delay.
            harvestDelay = newHarvestDelay;

            // Reset the next harvest delay.
            nextHarvestDelay = 0;

            emit HarvestDelayUpdated(msg.sender, newHarvestDelay);
        }
    }

    /*///////////////////////////////////////////////////////////////
                    STRATEGY DEPOSIT/WITHDRAWAL LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted after the Vault deposits into a strategy contract.
    /// @param user The authorized user who triggered the deposit.
    /// @param strategy The strategy that was deposited into.
    /// @param underlyingAmount The amount of underlying tokens that were deposited.
    event StrategyDeposit(
        address indexed user,
        Strategy indexed strategy,
        uint256 underlyingAmount
    );

    /// @notice Emitted after the Vault withdraws funds from a strategy contract.
    /// @param user The authorized user who triggered the withdrawal.
    /// @param strategy The strategy that was withdrawn from.
    /// @param underlyingAmount The amount of underlying tokens that were withdrawn.
    event StrategyWithdrawal(
        address indexed user,
        Strategy indexed strategy,
        uint256 underlyingAmount
    );

    /// @notice Deposit a specific amount of float into a trusted strategy.
    /// @param strategy The trusted strategy to deposit into.
    /// @param underlyingAmount The amount of underlying tokens in float to deposit.
    function depositIntoStrategy(Strategy strategy, uint256 underlyingAmount)
        external
        onlyOwner
    {
        // A strategy must be trusted before it can be deposited into.
        require(getStrategyData[strategy].trusted, "UNTRUSTED_STRATEGY");

        // Increase totalStrategyHoldings to account for the deposit.
        totalStrategyHoldings += underlyingAmount;

        unchecked {
            // Without this the next harvest would count the deposit as profit.
            // Cannot overflow as the balance of one strategy can't exceed the sum of all.
            getStrategyData[strategy].balance += underlyingAmount
                .safeCastTo248();
        }

        emit StrategyDeposit(msg.sender, strategy, underlyingAmount);

        // Approve underlyingAmount to the strategy so we can deposit.
        UNDERLYING.safeApprove(address(strategy), underlyingAmount);

        // Deposit into the strategy and revert if it returns an error code.
        require(strategy.deposit(underlyingAmount) == 0, "deposit_FAILED");
    }

    /// @notice Withdraw a specific amount of underlying tokens from a strategy.
    /// @param strategy The strategy to withdraw from.
    /// @param underlyingAmount  The amount of underlying tokens to withdraw.
    /// @dev Withdrawing from a strategy will not remove it from the withdrawal stack.
    function withdrawFromStrategy(Strategy strategy, uint256 underlyingAmount)
        external
        onlyOwner
    {
        // A strategy must be trusted before it can be withdrawn from.
        require(getStrategyData[strategy].trusted, "UNTRUSTED_STRATEGY");

        // Without this the next harvest would count the withdrawal as a loss.
        getStrategyData[strategy].balance -= underlyingAmount.safeCastTo248();

        unchecked {
            // Decrease totalStrategyHoldings to account for the withdrawal.
            // Cannot underflow as the balance of one strategy will never exceed the sum of all.
            totalStrategyHoldings -= underlyingAmount;
        }

        emit StrategyWithdrawal(msg.sender, strategy, underlyingAmount);

        // Withdraw from the strategy and revert if it returns an error code.
        require(strategy.withdraw(underlyingAmount) == 0, "REDEEM_FAILED");
    }

    /*///////////////////////////////////////////////////////////////
                      STRATEGY TRUST/DISTRUST LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a strategy is set to trusted.
    /// @param user The authorized user who trusted the strategy.
    /// @param strategy The strategy that became trusted.
    event StrategyTrusted(address indexed user, Strategy indexed strategy);

    /// @notice Emitted when a strategy is set to untrusted.
    /// @param user The authorized user who untrusted the strategy.
    /// @param strategy The strategy that became untrusted.
    event StrategyDistrusted(address indexed user, Strategy indexed strategy);

    /// @notice Stores a strategy as trusted, enabling it to be harvested.
    /// @param strategy The strategy to make trusted.
    function trustStrategy(Strategy strategy) external onlyOwner {
        // Ensure the strategy accepts the correct underlying token.
        // If the strategy accepts ETH the Vault should accept WETH, it'll handle wrapping when necessary.
        require(
            Strategy(address(strategy)).underlying() == UNDERLYING,
            "WRONG_UNDERLYING"
        );

        // Store the strategy as trusted.
        getStrategyData[strategy].trusted = true;

        emit StrategyTrusted(msg.sender, strategy);
    }

    /// @notice Stores a strategy as untrusted, disabling it from being harvested.
    /// @param strategy The strategy to make untrusted.
    function distrustStrategy(Strategy strategy) external onlyOwner {
        // Store the strategy as untrusted.
        getStrategyData[strategy].trusted = false;

        emit StrategyDistrusted(msg.sender, strategy);
    }

    /*///////////////////////////////////////////////////////////////
                         WITHDRAWAL STACK LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a strategy is pushed to the withdrawal stack.
    /// @param user The authorized user who triggered the push.
    /// @param pushedStrategy The strategy pushed to the withdrawal stack.
    event WithdrawalStackPushed(
        address indexed user,
        Strategy indexed pushedStrategy
    );

    /// @notice Emitted when a strategy is popped from the withdrawal stack.
    /// @param user The authorized user who triggered the pop.
    /// @param poppedStrategy The strategy popped from the withdrawal stack.
    event WithdrawalStackPopped(
        address indexed user,
        Strategy indexed poppedStrategy
    );

    /// @notice Emitted when the withdrawal stack is updated.
    /// @param user The authorized user who triggered the set.
    /// @param replacedWithdrawalStack The new withdrawal stack.
    event WithdrawalStackSet(
        address indexed user,
        Strategy[] replacedWithdrawalStack
    );

    /// @notice Emitted when an index in the withdrawal stack is replaced.
    /// @param user The authorized user who triggered the replacement.
    /// @param index The index of the replaced strategy in the withdrawal stack.
    /// @param replacedStrategy The strategy in the withdrawal stack that was replaced.
    /// @param replacementStrategy The strategy that overrode the replaced strategy at the index.
    event WithdrawalStackIndexReplaced(
        address indexed user,
        uint256 index,
        Strategy indexed replacedStrategy,
        Strategy indexed replacementStrategy
    );

    /// @notice Emitted when an index in the withdrawal stack is replaced with the tip.
    /// @param user The authorized user who triggered the replacement.
    /// @param index The index of the replaced strategy in the withdrawal stack.
    /// @param replacedStrategy The strategy in the withdrawal stack replaced by the tip.
    /// @param previousTipStrategy The previous tip of the stack that replaced the strategy.
    event WithdrawalStackIndexReplacedWithTip(
        address indexed user,
        uint256 index,
        Strategy indexed replacedStrategy,
        Strategy indexed previousTipStrategy
    );

    /// @notice Emitted when the strategies at two indexes are swapped.
    /// @param user The authorized user who triggered the swap.
    /// @param index1 One index involved in the swap
    /// @param index2 The other index involved in the swap.
    /// @param newStrategy1 The strategy (previously at index2) that replaced index1.
    /// @param newStrategy2 The strategy (previously at index1) that replaced index2.
    event WithdrawalStackIndexesSwapped(
        address indexed user,
        uint256 index1,
        uint256 index2,
        Strategy indexed newStrategy1,
        Strategy indexed newStrategy2
    );

    /// @dev Withdraw a specific amount of underlying tokens from strategies in the withdrawal stack.
    /// @param underlyingAmount The amount of underlying tokens to pull into float.
    /// @dev Automatically removes depleted strategies from the withdrawal stack.
    function pullFromWithdrawalStack(uint256 underlyingAmount) internal {
        // We will update this variable as we pull from strategies.
        uint256 amountLeftToPull = underlyingAmount;

        // We'll start at the tip of the stack and traverse backwards.
        uint256 currentIndex = withdrawalStack.length - 1;

        // Iterate in reverse so we pull from the stack in a "last in, first out" manner.
        // Will revert due to underflow if we empty the stack before pulling the desired amount.
        for (; ; currentIndex--) {
            // Get the strategy at the current stack index.
            Strategy strategy = withdrawalStack[currentIndex];

            // Get the balance of the strategy before we withdraw from it.
            uint256 strategyBalance = getStrategyData[strategy].balance;

            // If the strategy is currently untrusted or was already depleted:
            if (!getStrategyData[strategy].trusted || strategyBalance == 0) {
                // Remove it from the stack.
                withdrawalStack.pop();

                emit WithdrawalStackPopped(msg.sender, strategy);

                // Move onto the next strategy.
                continue;
            }

            // We want to pull as much as we can from the strategy, but no more than we need.
            uint256 amountToPull = strategyBalance > amountLeftToPull
                ? amountLeftToPull
                : strategyBalance;

            unchecked {
                // Compute the balance of the strategy that will remain after we withdraw.
                // Cannot underflow as we cap the amount to pull at the strategy's balance.
                uint256 strategyBalanceAfterWithdrawal = strategyBalance -
                    amountToPull;

                // Without this the next harvest would count the withdrawal as a loss.
                getStrategyData[strategy]
                    .balance = strategyBalanceAfterWithdrawal.safeCastTo248();

                // Adjust our goal based on how much we can pull from the strategy.
                // Cannot underflow as we cap the amount to pull at the amount left to pull.
                amountLeftToPull -= amountToPull;

                emit StrategyWithdrawal(msg.sender, strategy, amountToPull);

                // Withdraw from the strategy and revert if returns an error code.
                require(strategy.withdraw(amountToPull) == 0, "REDEEM_FAILED");

                // If we fully depleted the strategy:
                if (strategyBalanceAfterWithdrawal == 0) {
                    // Remove it from the stack.
                    withdrawalStack.pop();

                    emit WithdrawalStackPopped(msg.sender, strategy);
                }
            }

            // If we've pulled all we need, exit the loop.
            if (amountLeftToPull == 0) break;
        }

        unchecked {
            // Account for the withdrawals done in the loop above.
            // Cannot underflow as the balances of some strategies cannot exceed the sum of all.
            totalStrategyHoldings -= underlyingAmount;
        }
    }

    /// @notice Pushes a single strategy to front of the withdrawal stack.
    /// @param strategy The strategy to be inserted at the front of the withdrawal stack.
    /// @dev Strategies that are untrusted, duplicated, or have no balance are
    /// filtered out when encountered at withdrawal time, not validated upfront.
    function pushToWithdrawalStack(Strategy strategy) external onlyOwner {
        // Ensure pushing the strategy will not cause the stack exceed its limit.
        require(
            withdrawalStack.length < MAX_WITHDRAWAL_STACK_SIZE,
            "STACK_FULL"
        );

        // Push the strategy to the front of the stack.
        withdrawalStack.push(strategy);

        emit WithdrawalStackPushed(msg.sender, strategy);
    }

    /// @notice Removes the strategy at the tip of the withdrawal stack.
    /// @dev Be careful, another authorized user could push a different strategy
    /// than expected to the stack while a popFromWithdrawalStack transaction is pending.
    function popFromWithdrawalStack() external onlyOwner {
        // Get the (soon to be) popped strategy.
        Strategy poppedStrategy = withdrawalStack[withdrawalStack.length - 1];

        // Pop the first strategy in the stack.
        withdrawalStack.pop();

        emit WithdrawalStackPopped(msg.sender, poppedStrategy);
    }

    /// @notice Sets a new withdrawal stack.
    /// @param newStack The new withdrawal stack.
    /// @dev Strategies that are untrusted, duplicated, or have no balance are
    /// filtered out when encountered at withdrawal time, not validated upfront.
    function setWithdrawalStack(Strategy[] calldata newStack)
        external
        onlyOwner
    {
        // Ensure the new stack is not larger than the maximum stack size.
        require(newStack.length <= MAX_WITHDRAWAL_STACK_SIZE, "STACK_TOO_BIG");

        // Replace the withdrawal stack.
        withdrawalStack = newStack;

        emit WithdrawalStackSet(msg.sender, newStack);
    }

    /// @notice Replaces an index in the withdrawal stack with another strategy.
    /// @param index The index in the stack to replace.
    /// @param replacementStrategy The strategy to override the index with.
    /// @dev Strategies that are untrusted, duplicated, or have no balance are
    /// filtered out when encountered at withdrawal time, not validated upfront.
    function replaceWithdrawalStackIndex(
        uint256 index,
        Strategy replacementStrategy
    ) external onlyOwner {
        // Get the (soon to be) replaced strategy.
        Strategy replacedStrategy = withdrawalStack[index];

        // Update the index with the replacement strategy.
        withdrawalStack[index] = replacementStrategy;

        emit WithdrawalStackIndexReplaced(
            msg.sender,
            index,
            replacedStrategy,
            replacementStrategy
        );
    }

    /// @notice Moves the strategy at the tip of the stack to the specified index and pop the tip off the stack.
    /// @param index The index of the strategy in the withdrawal stack to replace with the tip.
    function replaceWithdrawalStackIndexWithTip(uint256 index)
        external
        onlyOwner
    {
        // Get the (soon to be) previous tip and strategy we will replace at the index.
        Strategy previousTipStrategy = withdrawalStack[
            withdrawalStack.length - 1
        ];
        Strategy replacedStrategy = withdrawalStack[index];

        // Replace the index specified with the tip of the stack.
        withdrawalStack[index] = previousTipStrategy;

        // Remove the now duplicated tip from the array.
        withdrawalStack.pop();

        emit WithdrawalStackIndexReplacedWithTip(
            msg.sender,
            index,
            replacedStrategy,
            previousTipStrategy
        );
    }

    /// @notice Swaps two indexes in the withdrawal stack.
    /// @param index1 One index involved in the swap
    /// @param index2 The other index involved in the swap.
    function swapWithdrawalStackIndexes(uint256 index1, uint256 index2)
        external
        onlyOwner
    {
        // Get the (soon to be) new strategies at each index.
        Strategy newStrategy2 = withdrawalStack[index1];
        Strategy newStrategy1 = withdrawalStack[index2];

        // Swap the strategies at both indexes.
        withdrawalStack[index1] = newStrategy1;
        withdrawalStack[index2] = newStrategy2;

        emit WithdrawalStackIndexesSwapped(
            msg.sender,
            index1,
            index2,
            newStrategy1,
            newStrategy2
        );
    }

    /*///////////////////////////////////////////////////////////////
                             FEE CLAIM LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted after fees are claimed.
    /// @param user The authorized user who claimed the fees.
    /// @param rvTokenAmount The amount of rvTokens that were claimed.
    event FeesClaimed(address indexed user, uint256 rvTokenAmount);

    /// @notice Claims fees accrued from harvests.
    /// @param rvTokenAmount The amount of rvTokens to claim.
    /// @dev Accrued fees are measured as rvTokens held by the Vault.
    function claimFees(uint256 rvTokenAmount) external onlyOwner {
        emit FeesClaimed(msg.sender, rvTokenAmount);

        // Transfer the provided amount of rvTokens to the caller.
        ERC20(this).safeTransfer(msg.sender, rvTokenAmount);
    }

    /*///////////////////////////////////////////////////////////////
                    INITIALIZATION AND DESTRUCTION LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the Vault is initialized.
    /// @param user The authorized user who triggered the initialization.
    event Initialized(address indexed user);

    /// @notice Whether the Vault has been initialized yet.
    /// @dev Can go from false to true, never from true to false.
    bool public isInitialized;

    /// @notice Initializes the Vault, enabling it to receive deposits.
    /// @dev All critical parameters must already be set before calling.
    function initialize() external onlyOwner {
        // Ensure the Vault has not already been initialized.
        require(!isInitialized, "ALREADY_INITIALIZED");

        // Mark the Vault as initialized.
        isInitialized = true;

        // Open for deposits.
        totalSupply = 0;

        emit Initialized(msg.sender);
    }

    /// @notice Self destructs a Vault, enabling it to be redeployed.
    /// @dev Caller will receive any ETH held as float in the Vault.
    function destroy() external onlyOwner {
        selfdestruct(payable(msg.sender));
    }

    /*///////////////////////////////////////////////////////////////
                          RECIEVE ETHER LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @dev Required for the Vault to receive unwrapped ETH.
    receive() external payable {}
}
