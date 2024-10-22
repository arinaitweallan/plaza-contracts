// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {BondToken} from "./BondToken.sol";
import {Decimals} from "./lib/Decimals.sol";
import {Distributor} from "./Distributor.sol";
import {PoolFactory} from "./PoolFactory.sol";
import {Validator} from "./utils/Validator.sol";
import {OracleReader} from "./OracleReader.sol";
import {LeverageToken} from "./LeverageToken.sol";
import {ERC20Extensions} from "./lib/ERC20Extensions.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/**
 * @title Pool
 * @dev This contract manages a pool of assets, allowing for the creation, redemption, and swapping of bond and leverage tokens.
 * It also handles distribution periods and interacts with an oracle for price information.
 */
contract Pool is Initializable, PausableUpgradeable, ReentrancyGuardUpgradeable, OracleReader, Validator {
  using Decimals for uint256;
  using SafeERC20 for IERC20;
  using ERC20Extensions for IERC20;
  
  // Constants
  uint256 private constant POINT_EIGHT = 800000; // 1000000 precision | 800000=0.8
  uint256 private constant POINT_TWO = 200000;
  uint256 private constant COLLATERAL_THRESHOLD = 1200000;
  uint256 private constant PRECISION = 1000000;
  uint256 private constant BOND_TARGET_PRICE = 100;
  uint8 private constant COMMON_DECIMALS = 18;

  // Protocol
  PoolFactory public poolFactory;
  uint256 private fee;

  // Tokens
  address public reserveToken;
  BondToken public bondToken;
  LeverageToken public lToken;

  // Coupon
  address public couponToken;

  // Distribution
  uint256 private sharesPerToken;
  uint256 private distributionPeriod; // in seconds
  uint256 private lastDistribution; // timestamp in seconds

  /**
   * @dev Enum representing the types of tokens that can be created or redeemed.
   */
  enum TokenType {
    BOND, // bond
    LEVERAGE
  }

  /**
   * @dev Struct containing information about the pool's current state.
   */
  struct PoolInfo {
    uint256 fee;
    uint256 reserve; //underlying token amount
    uint256 bondSupply;
    uint256 levSupply;
    uint256 sharesPerToken;
    uint256 currentPeriod;
    uint256 lastDistribution;
    uint256 distributionPeriod;
  }

  // Custom errors
  error MinAmount();
  error ZeroAmount();
  error AccessDenied();
  error ZeroDebtSupply();
  error ZeroLeverageSupply();
  error DistributionPeriod();

  // Events
  event TokensCreated(address caller, address onBehalfOf, TokenType tokenType, uint256 depositedAmount, uint256 mintedAmount);
  event TokensRedeemed(address caller, address onBehalfOf, TokenType tokenType, uint256 depositedAmount, uint256 redeemedAmount);
  event TokensSwapped(address caller, address onBehalfOf, TokenType tokenType, uint256 depositedAmount, uint256 redeemedAmount);
  event DistributionPeriodChanged(uint256 oldPeriod, uint256 newPeriod);
  event SharesPerTokenChanged(uint256 sharesPerToken);
  event Distributed(uint256 amount);
  
  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /**
   * @dev Initializes the contract with the given parameters.
   * @param _poolFactory Address of the pool factory contract.
   * @param _fee Fee percentage for the pool.
   * @param _reserveToken Address of the reserve token.
   * @param _dToken Address of the bond token.
   * @param _lToken Address of the leverage token.
   * @param _couponToken Address of the coupon token.
   * @param _sharesPerToken Initial shares per bond per distribution period.
   * @param _distributionPeriod Initial distribution period in seconds.
   * @param _oracleFeeds Address of the OracleFeeds contract.
   */
  function initialize(
    address _poolFactory,
    uint256 _fee,
    address _reserveToken,
    address _dToken,
    address _lToken,
    address _couponToken,
    uint256 _sharesPerToken,
    uint256 _distributionPeriod,
    address _oracleFeeds
  ) initializer public {
    __OracleReader_init(_oracleFeeds);
    __ReentrancyGuard_init();

    poolFactory = PoolFactory(_poolFactory);
    fee = _fee;
    reserveToken = _reserveToken;
    bondToken = BondToken(_dToken);
    lToken = LeverageToken(_lToken);
    couponToken = _couponToken;
    sharesPerToken = _sharesPerToken;
    distributionPeriod = _distributionPeriod;
    lastDistribution = block.timestamp;
  }

  /**
   * @dev Creates new tokens by depositing reserve tokens.
   * @param tokenType The type of token to create (BOND or LEVERAGE).
   * @param depositAmount The amount of reserve tokens to deposit.
   * @param minAmount The minimum amount of new tokens to receive.
   * @return amount of new tokens created.
   */
  function create(TokenType tokenType, uint256 depositAmount, uint256 minAmount) external whenNotPaused() nonReentrant() returns(uint256) {
    return _create(tokenType, depositAmount, minAmount, address(0));
  }

  /**
   * @dev Creates new tokens by depositing reserve tokens, with additional parameters for deadline and onBehalfOf for router support.
   * @param tokenType The type of token to create (BOND or LEVERAGE).
   * @param depositAmount The amount of reserve tokens to deposit.
   * @param minAmount The minimum amount of new tokens to receive.
   * @param deadline The deadline timestamp in seconds for the transaction to be executed.
   * @param onBehalfOf The address to receive the new tokens.
   * @return The amount of new tokens created.
   */
  function create(
    TokenType tokenType,
    uint256 depositAmount,
    uint256 minAmount,
    uint256 deadline,
    address onBehalfOf) external whenNotPaused() nonReentrant() checkDeadline(deadline) returns(uint256) {
    return _create(tokenType, depositAmount, minAmount, onBehalfOf);
  }
  
  /**
   * @dev Creates new tokens by depositing reserve tokens, with additional parameters for deadline and onBehalfOf for router support.
   * @param tokenType The type of token to create (BOND or LEVERAGE).
   * @param depositAmount The amount of reserve tokens to deposit.
   * @param minAmount The minimum amount of new tokens to receive.
   * @param onBehalfOf The address to receive the new tokens.
   * @return The amount of new tokens created.
   */
  function _create(
    TokenType tokenType,
    uint256 depositAmount,
    uint256 minAmount,
    address onBehalfOf) private returns(uint256) {
    // Get amount to mint
    uint256 amount = simulateCreate(tokenType, depositAmount);
    
    // Check slippage
    if (amount < minAmount) {
      revert MinAmount();
    }

    // Mint amount should be higher than zero
    if (amount == 0) {
      revert ZeroAmount();
    }

    address recipient = onBehalfOf == address(0) ? msg.sender : onBehalfOf;

    // Mint tokens
    if (tokenType == TokenType.BOND) {
      bondToken.mint(recipient, amount);
    } else {
      lToken.mint(recipient, amount);
    }

    IERC20(reserveToken).safeTransferFrom(msg.sender, address(this), depositAmount);

    emit TokensCreated(msg.sender, recipient, tokenType, depositAmount, amount);
    return amount;
  }

  /**
   * @dev Simulates the creation of new tokens without actually minting them.
   * @param tokenType The type of token to simulate creating (BOND or LEVERAGE).
   * @param depositAmount The amount of reserve tokens to simulate depositing.
   * @return amount of new tokens that would be created.
   */
  function simulateCreate(TokenType tokenType, uint256 depositAmount) public view returns(uint256) {
    require(depositAmount > 0, ZeroAmount());

    uint256 bondSupply = bondToken.totalSupply()
                          .normalizeTokenAmount(address(bondToken), COMMON_DECIMALS);
    uint256 levSupply = lToken.totalSupply()
                          .normalizeTokenAmount(address(lToken), COMMON_DECIMALS);
    uint256 poolReserves = IERC20(reserveToken).balanceOf(address(this))
                          .normalizeTokenAmount(reserveToken, COMMON_DECIMALS);
    depositAmount = depositAmount.normalizeTokenAmount(reserveToken, COMMON_DECIMALS);

    uint8 assetDecimals = 0;
    if (tokenType == TokenType.LEVERAGE) {
      assetDecimals = lToken.decimals();
    } else {
      assetDecimals = bondToken.decimals();
    }

    return getCreateAmount(
      tokenType,
      depositAmount,
      bondSupply,
      levSupply,
      poolReserves,
      getOraclePrice(reserveToken, USD),
      getOracleDecimals(reserveToken, USD)
    ).normalizeAmount(COMMON_DECIMALS, assetDecimals);
  }

  /**
   * @dev Calculates the amount of new tokens to create based on the current pool state and oracle price.
   * @param tokenType The type of token to create (BOND or LEVERAGE).
   * @param depositAmount The amount of reserve tokens to deposit.
   * @param bondSupply The current supply of bond tokens.
   * @param levSupply The current supply of leverage tokens.
   * @param poolReserves The current amount of reserve tokens in the pool.
   * @param ethPrice The current ETH price from the oracle.
   * @param oracleDecimals The number of decimals used by the oracle.
   * @return amount of new tokens to create.
   */
  function getCreateAmount(
    TokenType tokenType,
    uint256 depositAmount,
    uint256 bondSupply, 
    uint256 levSupply, 
    uint256 poolReserves, 
    uint256 ethPrice,
    uint8 oracleDecimals) public pure returns(uint256) {
    if (bondSupply == 0) {
      revert ZeroDebtSupply();
    }

    uint256 assetSupply = bondSupply;
    uint256 multiplier = POINT_EIGHT;
    if (tokenType == TokenType.LEVERAGE) {
      multiplier = POINT_TWO;
      assetSupply = levSupply;
    }

    uint256 tvl = (ethPrice * poolReserves).toBaseUnit(oracleDecimals);
    uint256 collateralLevel = (tvl * PRECISION) / (bondSupply * BOND_TARGET_PRICE);
    uint256 creationRate = BOND_TARGET_PRICE * PRECISION;

    if (collateralLevel <= COLLATERAL_THRESHOLD) {
      creationRate = (tvl * multiplier) / assetSupply;
    } else if (tokenType == TokenType.LEVERAGE) {
      if (assetSupply == 0) {
        revert ZeroLeverageSupply();
      }

      uint256 adjustedValue = tvl - (BOND_TARGET_PRICE * bondSupply);
      creationRate = (adjustedValue * PRECISION) / assetSupply;
    }
    
    return ((depositAmount * ethPrice * PRECISION) / creationRate).toBaseUnit(oracleDecimals);
  }

  /**
   * @dev Redeems tokens for reserve tokens.
   * @param tokenType The type of derivative token to redeem (BOND or LEVERAGE).
   * @param depositAmount The amount of derivative tokens to redeem.
   * @param minAmount The minimum amount of reserve tokens to receive.
   * @return amount of reserve tokens received.
   */
  function redeem(TokenType tokenType, uint256 depositAmount, uint256 minAmount) public whenNotPaused() nonReentrant() returns(uint256) {
    return _redeem(tokenType, depositAmount, minAmount, address(0));
  }

  /**
   * @dev Redeems tokens for reserve tokens, with additional parameters.
   * @param tokenType The type of derivative token to redeem (BOND or LEVERAGE).
   * @param depositAmount The amount of derivative tokens to redeem.
   * @param minAmount The minimum amount of reserve tokens to receive.
   * @param deadline The deadline timestamp in seconds for the transaction to be executed.
   * @param onBehalfOf The address to receive the reserve tokens.
   * @return amount of reserve tokens received.
   */
  function redeem(
    TokenType tokenType,
    uint256 depositAmount,
    uint256 minAmount,
    uint256 deadline,
    address onBehalfOf) external whenNotPaused() nonReentrant() checkDeadline(deadline) returns(uint256) {
    return _redeem(tokenType, depositAmount, minAmount, onBehalfOf);
  }

  /**
   * @dev Redeems tokens for reserve tokens, with additional parameters.
   * @param tokenType The type of derivative token to redeem (BOND or LEVERAGE).
   * @param depositAmount The amount of derivative tokens to redeem.
   * @param minAmount The minimum amount of reserve tokens to receive.
   * @param onBehalfOf The address to receive the reserve tokens.
   * @return amount of reserve tokens received.
   */
  function _redeem(
    TokenType tokenType,
    uint256 depositAmount,
    uint256 minAmount,
    address onBehalfOf) private returns(uint256) {
    // Get amount to mint
    uint256 reserveAmount = simulateRedeem(tokenType, depositAmount);

    // Check whether reserve contains enough funds
    if (reserveAmount < minAmount) {
      revert MinAmount();
    }

    // Reserve amount should be higher than zero
    if (reserveAmount == 0) {
      revert ZeroAmount();
    }

    // Burn derivative tokens
    if (tokenType == TokenType.BOND) {
      bondToken.burn(msg.sender, depositAmount);
    } else {
      lToken.burn(msg.sender, depositAmount);
    }

    address recipient = onBehalfOf == address(0) ? msg.sender : onBehalfOf;

    IERC20(reserveToken).safeTransfer(recipient, reserveAmount);

    emit TokensRedeemed(msg.sender, recipient, tokenType, depositAmount, reserveAmount);
    return reserveAmount;
  }

  /**
   * @dev Simulates the redemption of tokens without actually burning them.
   * @param tokenType The type of derivative token to simulate redeeming (BOND or LEVERAGE).
   * @param depositAmount The amount of derivative tokens to simulate redeeming.
   * @return amount of reserve tokens that would be received.
   */
  function simulateRedeem(TokenType tokenType, uint256 depositAmount) public view returns(uint256) {
    require(depositAmount > 0, ZeroAmount());

    uint256 bondSupply = bondToken.totalSupply()
                          .normalizeTokenAmount(address(bondToken), COMMON_DECIMALS);
    uint256 levSupply = lToken.totalSupply()
                          .normalizeTokenAmount(address(lToken), COMMON_DECIMALS);
    uint256 poolReserves = IERC20(reserveToken).balanceOf(address(this))
                          .normalizeTokenAmount(reserveToken, COMMON_DECIMALS);

    if (tokenType == TokenType.LEVERAGE) {
      depositAmount = depositAmount.normalizeTokenAmount(address(lToken), COMMON_DECIMALS);
    } else {
      depositAmount = depositAmount.normalizeTokenAmount(address(bondToken), COMMON_DECIMALS);
    }

    return getRedeemAmount(
      tokenType,
      depositAmount,
      bondSupply,
      levSupply,
      poolReserves,
      getOraclePrice(reserveToken, USD),
      getOracleDecimals(reserveToken, USD)
    ).normalizeAmount(COMMON_DECIMALS, IERC20(reserveToken).safeDecimals());
  }

  /**
   * @dev Calculates the amount of reserve tokens to be redeemed for a given amount of bond or leverage tokens.
   * @param tokenType The type of derivative token being redeemed (BOND or LEVERAGE).
   * @param depositAmount The amount of derivative tokens being redeemed.
   * @param bondSupply The total supply of bond tokens.
   * @param levSupply The total supply of leverage tokens.
   * @param poolReserves The total amount of reserve tokens in the pool.
   * @param ethPrice The current ETH price from the oracle.
   * @param oracleDecimals The number of decimals used by the oracle.
   * @return amount of reserve tokens to be redeemed.
   */
  function getRedeemAmount(
    TokenType tokenType,
    uint256 depositAmount,
    uint256 bondSupply,
    uint256 levSupply,
    uint256 poolReserves,
    uint256 ethPrice,
    uint8 oracleDecimals
  ) public pure returns(uint256) {
    if (bondSupply == 0) {
      revert ZeroDebtSupply();
    }

    uint256 tvl = (ethPrice * poolReserves).toBaseUnit(oracleDecimals);
    uint256 assetSupply = bondSupply;
    uint256 multiplier = POINT_EIGHT;

    // Calculate the collateral level based on the token type
    uint256 collateralLevel;
    if (tokenType == TokenType.BOND) {
      collateralLevel = ((tvl - (depositAmount * BOND_TARGET_PRICE)) * PRECISION) / ((bondSupply - depositAmount) * BOND_TARGET_PRICE);
    } else {
      multiplier = POINT_TWO;
      assetSupply = levSupply;
      collateralLevel = (tvl * PRECISION) / (bondSupply * BOND_TARGET_PRICE);

      if (assetSupply == 0) {
        revert ZeroLeverageSupply();
      }
    }
    
    // Calculate the redeem rate based on the collateral level and token type
    uint256 redeemRate;
    if (collateralLevel <= COLLATERAL_THRESHOLD) {
      redeemRate = ((tvl * multiplier) / assetSupply);
    } else if (tokenType == TokenType.LEVERAGE) {
      redeemRate = ((tvl - (bondSupply * BOND_TARGET_PRICE)) / assetSupply) * PRECISION;
    } else {
      redeemRate = BOND_TARGET_PRICE * PRECISION;
    }
    
    // Calculate and return the final redeem amount
    return ((depositAmount * redeemRate).fromBaseUnit(oracleDecimals) / ethPrice) / PRECISION;
  }

  /**
   * @dev Swaps one token type for another (BOND for LEVERAGE or vice versa).
   * @param tokenType The type of derivative token being swapped.
   * @param depositAmount The amount of derivative tokens to swap.
   * @param minAmount The minimum amount of derivative tokens to receive in return.
   * @return amount of derivative tokens received in the swap.
   */
  function swap(TokenType tokenType, uint256 depositAmount, uint256 minAmount) public whenNotPaused() nonReentrant() returns(uint256) {
    return _swap(tokenType, depositAmount, minAmount, address(0));
  }

  /**
   * @dev Swaps one token type for another with additional parameters.
   * @param tokenType The type of derivative token being swapped.
   * @param depositAmount The amount of derivative tokens to swap.
   * @param minAmount The minimum amount of derivative tokens to receive in return.
   * @param deadline The deadline timestamp in seconds for the transaction to be executed.
   * @param onBehalfOf The address to receive the swapped derivative tokens.
   * @return amount of derivative tokens received in the swap.
   */
  function swap(
    TokenType tokenType,
    uint256 depositAmount,
    uint256 minAmount,
    uint256 deadline,
    address onBehalfOf
  ) public whenNotPaused() nonReentrant() checkDeadline(deadline) returns(uint256) {
    return _swap(tokenType, depositAmount, minAmount, onBehalfOf);
  }

  /**
   * @dev Swaps one token type for another with additional parameters.
   * @param tokenType The type of derivative token being swapped.
   * @param depositAmount The amount of derivative tokens to swap.
   * @param minAmount The minimum amount of derivative tokens to receive in return.
   * @param onBehalfOf The address to receive the swapped derivative tokens.
   * @return amount of derivative tokens received in the swap.
   */
  function _swap(
    TokenType tokenType,
    uint256 depositAmount,
    uint256 minAmount,
    address onBehalfOf
  ) private returns(uint256) {
    uint256 mintAmount = simulateSwap(tokenType, depositAmount);

    if (mintAmount < minAmount) {
      revert MinAmount();
    }

    address recipient = onBehalfOf == address(0) ? msg.sender : onBehalfOf;

    if (tokenType == TokenType.BOND) {
      bondToken.burn(msg.sender, depositAmount);
      lToken.mint(recipient, mintAmount);
    } else {
      lToken.burn(msg.sender, depositAmount);
      bondToken.mint(recipient, mintAmount);
    }

    emit TokensSwapped(msg.sender, recipient, tokenType, depositAmount, mintAmount);
    return mintAmount;
  }

  /**
   * @dev Simulates a swap without actually executing it.
   * @param tokenType The type of derivative token being swapped.
   * @param depositAmount The amount of derivative tokens to simulate swapping.
   * @return amount of derivative tokens that would be received in the swap.
   */
  function simulateSwap(TokenType tokenType, uint256 depositAmount) public view returns(uint256) {
    require(depositAmount > 0, ZeroAmount());

    uint256 bondSupply = bondToken.totalSupply()
                          .normalizeTokenAmount(address(bondToken), COMMON_DECIMALS);
    uint256 levSupply = lToken.totalSupply()
                          .normalizeTokenAmount(address(lToken), COMMON_DECIMALS);
    uint256 poolReserves = IERC20(reserveToken).balanceOf(address(this))
                          .normalizeTokenAmount(reserveToken, COMMON_DECIMALS);

    if (tokenType == TokenType.LEVERAGE) {
      depositAmount = depositAmount.normalizeTokenAmount(address(lToken), COMMON_DECIMALS);
    } else {
      depositAmount = depositAmount.normalizeTokenAmount(address(bondToken), COMMON_DECIMALS);
    }

    uint256 redeemAmount = getRedeemAmount(
      tokenType,
      depositAmount,
      bondSupply,
      levSupply,
      poolReserves,
      getOraclePrice(reserveToken, USD),
      getOracleDecimals(reserveToken, USD)
    );
    
    uint8 assetDecimals = 0;
    TokenType createType = TokenType.BOND;
    poolReserves = poolReserves - redeemAmount;

    if (tokenType == TokenType.BOND) {
      createType = TokenType.LEVERAGE;
      bondSupply = bondSupply - depositAmount; 
      assetDecimals = lToken.decimals();
    } else {
      levSupply = levSupply - depositAmount; 
      assetDecimals = bondToken.decimals();
    }

    return getCreateAmount(
      createType,
      redeemAmount,
      bondSupply,
      levSupply,
      poolReserves,
      getOraclePrice(reserveToken, USD),
      getOracleDecimals(reserveToken, USD)
    ).normalizeAmount(COMMON_DECIMALS, assetDecimals);
  }

  /**
   * @dev Distributes coupon tokens to bond token holders.
   * Can only be called after the distribution period has passed.
   */
  function distribute() external whenNotPaused() {
    if (block.timestamp - lastDistribution < distributionPeriod) {
      revert DistributionPeriod();
    }

    Distributor distributor = Distributor(poolFactory.distributor());

    // Calculate last distribution time
    lastDistribution = block.timestamp + distributionPeriod;

    uint8 bondDecimals = bondToken.decimals();
    uint8 sharesDecimals = bondToken.SHARES_DECIMALS();
    uint8 maxDecimals = bondDecimals > sharesDecimals ? bondDecimals : sharesDecimals;

    uint256 normalizedTotalSupply = bondToken.totalSupply().normalizeAmount(bondDecimals, maxDecimals);
    uint256 normalizedShares = sharesPerToken.normalizeAmount(sharesDecimals, maxDecimals);

    // Calculate the coupon amount to distribute
    uint256 couponAmountToDistribute = (normalizedTotalSupply * normalizedShares)
        .toBaseUnit(maxDecimals * 2 - IERC20(couponToken).safeDecimals());
    
    // Increase the bond token period
    bondToken.increaseIndexedAssetPeriod(sharesPerToken);

    // Transfer coupon tokens to the distributor
    IERC20(couponToken).safeTransfer(address(distributor), couponAmountToDistribute);

    // Update distributor with the amount to distribute
    distributor.allocate(address(this), couponAmountToDistribute);

    emit Distributed(couponAmountToDistribute);
  }

  /**
   * @dev Returns the current pool information.
   * @return info A struct containing various pool parameters and balances.
   */
  function getPoolInfo() external view returns (PoolInfo memory info) {
    (uint256 currentPeriod, uint256 _sharesPerToken) = bondToken.globalPool();

    info = PoolInfo({
      fee: fee,
      distributionPeriod: distributionPeriod,
      reserve: IERC20(reserveToken).balanceOf(address(this)),
      bondSupply: bondToken.totalSupply(),
      levSupply: lToken.totalSupply(),
      sharesPerToken: _sharesPerToken,
      currentPeriod: currentPeriod,
      lastDistribution: lastDistribution
    });
  }
  
  /**
   * @dev Sets the distribution period.
   * @param _distributionPeriod The new distribution period.
   */
  function setDistributionPeriod(uint256 _distributionPeriod) external onlyRole(poolFactory.GOV_ROLE()) {
    uint256 oldPeriod = distributionPeriod;
    distributionPeriod = _distributionPeriod;

    emit DistributionPeriodChanged(oldPeriod, _distributionPeriod);
  }
  
  /**
   * @dev Sets the shares per token.
   * @param _sharesPerToken The new shares per token value.
   */
  function setSharesPerToken(uint256 _sharesPerToken) external onlyRole(poolFactory.GOV_ROLE()) {
    sharesPerToken = _sharesPerToken;

    emit SharesPerTokenChanged(sharesPerToken);
  }

  /**
   * @dev Sets the fee for the pool.
   * @param _fee The new fee value.
   */
  function setFee(uint256 _fee) external whenNotPaused() onlyRole(poolFactory.GOV_ROLE()) {
    fee = _fee;
  }

  /**
   * @dev Pauses the contract. Reverts any interaction except upgrade.
   */
  function pause() external onlyRole(poolFactory.GOV_ROLE()) {
    _pause();
  }

  /**
   * @dev Unpauses the contract.
   */
  function unpause() external onlyRole(poolFactory.GOV_ROLE()) {
    _unpause();
  }

  /**
   * @dev Modifier to check if the caller has the specified role.
   * @param role The role to check for.
   */
  modifier onlyRole(bytes32 role) {
    if (!poolFactory.hasRole(role, msg.sender)) {
      revert AccessDenied();
    }
    _;
  }
}
