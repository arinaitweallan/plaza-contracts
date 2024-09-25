// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Pool} from "../src/Pool.sol";
import {Token} from "./mocks/Token.sol";
import {Utils} from "../src/lib/Utils.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {BondToken} from "../src/BondToken.sol";
import {TestCases} from "./data/TestCases.sol";
import {PoolFactory} from "../src/PoolFactory.sol";
import {Distributor} from "../src/Distributor.sol";
import {Validator} from "../src/utils/Validator.sol";
import {LeverageToken} from "../src/LeverageToken.sol";
import {MockPriceFeed} from "./mocks/MockPriceFeed.sol";
import {TokenDeployer} from "../src/utils/TokenDeployer.sol";

contract PoolTest is Test, TestCases {
  PoolFactory private poolFactory;
  PoolFactory.PoolParams private params;

  Distributor private distributor;

  address private deployer = address(0x1);
  address private minter = address(0x2);
  address private governance = address(0x3);
  address private user = address(0x4);
  address private user2 = address(0x5);

  

  address public constant ethPriceFeed = address(0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70);
  uint256 private constant CHAINLINK_DECIMAL_PRECISION = 10**8;
  uint8 private constant CHAINLINK_DECIMAL = 8;

  /**
   * @dev Sets up the testing environment.
   * Deploys the BondToken contract and a proxy, then initializes them.
   * Grants the minter and governance roles and mints initial tokens.
   */
  function setUp() public {
    vm.startPrank(deployer);

    address tokenDeployer = address(new TokenDeployer());
    distributor = Distributor(Utils.deploy(address(new Distributor()), abi.encodeCall(Distributor.initialize, (governance))));
    poolFactory = PoolFactory(Utils.deploy(address(new PoolFactory()), abi.encodeCall(PoolFactory.initialize, (governance,tokenDeployer, address(distributor), ethPriceFeed))));

    params.fee = 0;
    params.reserveToken = address(new Token("Wrapped ETH", "WETH", false, address(0x0)));
    params.sharesPerToken = 50 * 10 ** 18;
    params.distributionPeriod = 0;
    params.couponToken = address(new Token("USDC", "USDC", false, address(0x0)));

    // Deploy the mock price feed
    MockPriceFeed mockPriceFeed = new MockPriceFeed();

    // Use vm.etch to deploy the mock contract at the specific address
    bytes memory bytecode = address(mockPriceFeed).code;
    vm.etch(ethPriceFeed, bytecode);

    // Set oracle price
    mockPriceFeed = MockPriceFeed(ethPriceFeed);
    mockPriceFeed.setMockPrice(3000 * int256(CHAINLINK_DECIMAL_PRECISION), uint8(CHAINLINK_DECIMAL));
    
    vm.stopPrank();

    vm.startPrank(governance);
    distributor.grantRole(distributor.POOL_FACTORY_ROLE(), address(poolFactory));
    vm.stopPrank();
  }

  function useMockPool(address poolAddress) public {
    // Deploy the mock pool
    MockPool mockPool = new MockPool();

    // Use vm.etch to deploy the mock contract at the specific address
    vm.etch(poolAddress, address(mockPool).code);
  }

  function setEthPrice(uint256 price) public {
    MockPriceFeed mockPriceFeed = MockPriceFeed(ethPriceFeed);
    mockPriceFeed.setMockPrice(int256(price), uint8(CHAINLINK_DECIMAL));
  }

  function resetReentrancy(address contractAddress) public {
    // Reset `_status` to allow the next call
    vm.store(
        contractAddress,
        bytes32(0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00), // Storage slot for `_status`
        bytes32(uint256(1))  // Reset to `_NOT_ENTERED`
    );
  }

  function testGetCreateAmount() public {
    initializeTestCases();
    
    vm.startPrank(governance);
    Token rToken = Token(params.reserveToken);

    for (uint256 i = 0; i < calcTestCases.length; i++) {
      rToken.mint(governance, calcTestCases[i].TotalUnderlyingAssets);
      rToken.approve(address(poolFactory), calcTestCases[i].TotalUnderlyingAssets);

      Pool _pool = Pool(poolFactory.CreatePool(params, calcTestCases[i].TotalUnderlyingAssets, calcTestCases[i].DebtAssets, calcTestCases[i].LeverageAssets));

      uint256 amount = _pool.getCreateAmount(
        calcTestCases[i].assetType, 
        calcTestCases[i].inAmount,
        calcTestCases[i].DebtAssets,
        calcTestCases[i].LeverageAssets,
        calcTestCases[i].TotalUnderlyingAssets,
        calcTestCases[i].ethPrice * CHAINLINK_DECIMAL_PRECISION,
        CHAINLINK_DECIMAL
      );
      assertEq(amount, calcTestCases[i].expectedCreate);

      // I can't set the ETH price will wait until we have oracles so I can mock
      // amount = _pool.simulateCreate(calcTestCases[i].assetType, calcTestCases[i].inAmount);
      // assertEq(amount, calcTestCases[i].expectedCreate);

      // Reset reserve state
      rToken.burn(governance, rToken.balanceOf(governance));
      rToken.burn(address(_pool), rToken.balanceOf(address(_pool)));
    }
  }

  function testGetCreateAmountZeroDebtSupply() public {
    Pool pool = new Pool();
    vm.expectRevert(Pool.ZeroDebtSupply.selector);
    pool.getCreateAmount(Pool.TokenType.BOND, 10, 0, 100, 100, 3000, CHAINLINK_DECIMAL);
  }

  function testGetCreateAmountZeroLeverageSupply() public {
    Pool pool = new Pool();
    vm.expectRevert(Pool.ZeroLeverageSupply.selector);
    pool.getCreateAmount(Pool.TokenType.LEVERAGE, 10, 100000, 0, 10000, 30000000 * CHAINLINK_DECIMAL_PRECISION, CHAINLINK_DECIMAL);
  }

  function testCreate() public {
    initializeTestCasesFixedEth();
    vm.startPrank(governance);
    Token rToken = Token(params.reserveToken);

    for (uint256 i = 0; i < calcTestCases.length; i++) {
      if (calcTestCases[i].inAmount == 0) {
        continue;
      }

      // Mint reserve tokens
      rToken.mint(governance, calcTestCases[i].TotalUnderlyingAssets + calcTestCases[i].inAmount);
      rToken.approve(address(poolFactory), calcTestCases[i].TotalUnderlyingAssets);

      // Create pool and approve deposit amount
      Pool _pool = Pool(poolFactory.CreatePool(params, calcTestCases[i].TotalUnderlyingAssets, calcTestCases[i].DebtAssets, calcTestCases[i].LeverageAssets));
      useMockPool(address(_pool));
      rToken.approve(address(_pool), calcTestCases[i].inAmount);

      uint256 startBondBalance = BondToken(_pool.bondToken()).balanceOf(governance);
      uint256 startLevBalance = LeverageToken(_pool.lToken()).balanceOf(governance);
      uint256 startReserveBalance = rToken.balanceOf(governance);

      vm.expectEmit(true, true, true, true);
      emit Pool.TokensCreated(governance, governance, calcTestCases[i].assetType, calcTestCases[i].inAmount, calcTestCases[i].expectedCreate);

      // Call create and assert minted tokens
      uint256 amount = _pool.create(calcTestCases[i].assetType, calcTestCases[i].inAmount, 0);
      assertEq(amount, calcTestCases[i].expectedCreate);

      uint256 endBondBalance = BondToken(_pool.bondToken()).balanceOf(governance);
      uint256 endLevBalance = LeverageToken(_pool.lToken()).balanceOf(governance);
      uint256 endReserveBalance = rToken.balanceOf(governance);
      assertEq(calcTestCases[i].inAmount, startReserveBalance-endReserveBalance);

      if (calcTestCases[i].assetType == Pool.TokenType.BOND) {
        assertEq(amount, endBondBalance-startBondBalance);
        assertEq(0, endLevBalance-startLevBalance);
      } else {
        assertEq(0, endBondBalance-startBondBalance);
        assertEq(amount, endLevBalance-startLevBalance);
      }

      // Reset reserve state
      rToken.burn(governance, rToken.balanceOf(governance));
      rToken.burn(address(_pool), rToken.balanceOf(address(_pool)));

      resetReentrancy(address(_pool));
    }
  }

  function testCreateOnBehalfOf() public {
    vm.startPrank(governance);
    Token rToken = Token(params.reserveToken);

    for (uint256 i = 0; i < calcTestCases.length; i++) {
      if (calcTestCases[i].inAmount == 0) {
        continue;
      }

      // Mint reserve tokens
      rToken.mint(governance, calcTestCases[i].TotalUnderlyingAssets + calcTestCases[i].inAmount);
      rToken.approve(address(poolFactory), calcTestCases[i].TotalUnderlyingAssets);

      // Create pool and approve deposit amount
      Pool _pool = Pool(poolFactory.CreatePool(params, calcTestCases[i].TotalUnderlyingAssets, calcTestCases[i].DebtAssets, calcTestCases[i].LeverageAssets));
      rToken.approve(address(_pool), calcTestCases[i].inAmount);

      uint256 startBondBalance = BondToken(_pool.bondToken()).balanceOf(user2);
      uint256 startLevBalance = LeverageToken(_pool.lToken()).balanceOf(user2);
      uint256 startReserveBalance = rToken.balanceOf(governance);

      // Call create and assert minted tokens
      uint256 amount = _pool.create(calcTestCases[i].assetType, calcTestCases[i].inAmount, 0, block.timestamp, user2);
      assertEq(amount, calcTestCases[i].expectedCreate);

      uint256 endBondBalance = BondToken(_pool.bondToken()).balanceOf(user2);
      uint256 endLevBalance = LeverageToken(_pool.lToken()).balanceOf(user2);
      uint256 endReserveBalance = rToken.balanceOf(governance);
      assertEq(calcTestCases[i].inAmount, startReserveBalance-endReserveBalance);

      if (calcTestCases[i].assetType == Pool.TokenType.BOND) {
        assertEq(amount, endBondBalance-startBondBalance);
        assertEq(0, endLevBalance-startLevBalance);
      } else {
        assertEq(0, endBondBalance-startBondBalance);
        assertEq(amount, endLevBalance-startLevBalance);
      }

      // Reset reserve state
      rToken.burn(governance, rToken.balanceOf(governance));
      rToken.burn(address(_pool), rToken.balanceOf(address(_pool)));

      resetReentrancy(address(_pool));
    }
  }

  function testCreateDeadlineExactSuccess() public {
    vm.startPrank(governance);
    Token rToken = Token(params.reserveToken);

    // Mint reserve tokens
    rToken.mint(governance, 10000001000);
    rToken.approve(address(poolFactory), 10000000000);

    // Create pool and approve deposit amount
    Pool _pool = Pool(poolFactory.CreatePool(params, 10000000000, 10000, 10000));

    rToken.approve(address(_pool), 1000);

    // Call create and assert minted tokens
    uint256 amount = _pool.create(Pool.TokenType.BOND, 1000, 30000, block.timestamp, governance);
    assertEq(amount, 30000);

    // Reset reserve state
    rToken.burn(governance, rToken.balanceOf(governance));
    rToken.burn(address(_pool), rToken.balanceOf(address(_pool)));
  }

  function testCreateDeadlineSuccess() public {
    vm.startPrank(governance);
    Token rToken = Token(params.reserveToken);

    // Mint reserve tokens
    rToken.mint(governance, 10000001000);
    rToken.approve(address(poolFactory), 10000000000);

    // Create pool and approve deposit amount
    Pool _pool = Pool(poolFactory.CreatePool(params, 10000000000, 10000, 10000));

    rToken.approve(address(_pool), 1000);

    // Call create and assert minted tokens
    uint256 amount = _pool.create(Pool.TokenType.BOND, 1000, 30000, block.timestamp + 10000, governance);
    assertEq(amount, 30000);

    // Reset reserve state
    rToken.burn(governance, rToken.balanceOf(governance));
    rToken.burn(address(_pool), rToken.balanceOf(address(_pool)));
  }

  function testCreateDeadlineRevert() public {
    vm.startPrank(governance);
    Token rToken = Token(params.reserveToken);

    // Mint reserve tokens
    rToken.mint(governance, 10000001000);
    rToken.approve(address(poolFactory), 10000000000);

    // Create pool and approve deposit amount
    Pool _pool = Pool(poolFactory.CreatePool(params, 10000000000, 10000, 10000));

    rToken.approve(address(_pool), 1000);

    // Call create and assert minted tokens
    vm.expectRevert(Validator.TransactionTooOld.selector);
    _pool.create(Pool.TokenType.BOND, 1000, 30000, block.timestamp - 1, governance);
  }

  function testCreateDeadlineSimulateBlockAdvanceRevert() public {
    vm.startPrank(governance);
    Token rToken = Token(params.reserveToken);

    // Mint reserve tokens
    rToken.mint(governance, 10000001000);
    rToken.approve(address(poolFactory), 10000000000);

    // Create pool and approve deposit amount
    Pool _pool = Pool(poolFactory.CreatePool(params, 10000000000, 10000, 10000));
    
    // Simulate block advanced
    useMockPool(address(_pool));
    MockPool(address(_pool)).setTime(block.timestamp + 1);

    rToken.approve(address(_pool), 1000);

    // Call create and assert minted tokens
    vm.expectRevert(Validator.TransactionTooOld.selector);
    _pool.create(Pool.TokenType.BOND, 1000, 30000, block.timestamp, governance);
  }

  function testCreateMinAmountExactSuccess() public {
    vm.startPrank(governance);
    Token rToken = Token(params.reserveToken);

    // Mint reserve tokens
    rToken.mint(governance, 10000001000);
    rToken.approve(address(poolFactory), 10000000000);

    // Create pool and approve deposit amount
    Pool _pool = Pool(poolFactory.CreatePool(params, 10000000000, 10000, 10000));
    rToken.approve(address(_pool), 1000);

    // Call create and assert minted tokens
    uint256 amount = _pool.create(Pool.TokenType.BOND, 1000, 30000);
    assertEq(amount, 30000);

    // Reset reserve state
    rToken.burn(governance, rToken.balanceOf(governance));
    rToken.burn(address(_pool), rToken.balanceOf(address(_pool)));
  }

  function testCreateMinAmountError() public {
    vm.startPrank(governance);
    Token rToken = Token(params.reserveToken);

    // Mint reserve tokens
    rToken.mint(governance, 10000001000);
    rToken.approve(address(poolFactory), 10000000000);

    // Create pool and approve deposit amount
    Pool _pool = Pool(poolFactory.CreatePool(params, 10000000000, 10000, 10000));
    rToken.approve(address(_pool), 1000);

    // Call create and expect error
    vm.expectRevert(Pool.MinAmount.selector);
    _pool.create(Pool.TokenType.BOND, 1000, 30001);

    // Reset reserve state
    rToken.burn(governance, rToken.balanceOf(governance));
    rToken.burn(address(_pool), rToken.balanceOf(address(_pool)));
  }

  function testGetRedeemAmount() public {
    initializeTestCases();
    
    vm.startPrank(governance);
    Token rToken = Token(params.reserveToken);

    for (uint256 i = 0; i < calcTestCases.length; i++) {
      rToken.mint(governance, calcTestCases[i].TotalUnderlyingAssets);
      rToken.approve(address(poolFactory), calcTestCases[i].TotalUnderlyingAssets);

      Pool _pool = Pool(poolFactory.CreatePool(params, calcTestCases[i].TotalUnderlyingAssets, calcTestCases[i].DebtAssets, calcTestCases[i].LeverageAssets));

      uint256 amount = _pool.getRedeemAmount(
        calcTestCases[i].assetType, 
        calcTestCases[i].inAmount, 
        calcTestCases[i].DebtAssets, 
        calcTestCases[i].LeverageAssets, 
        calcTestCases[i].TotalUnderlyingAssets, 
        calcTestCases[i].ethPrice * CHAINLINK_DECIMAL_PRECISION,
        CHAINLINK_DECIMAL
      );
      assertEq(amount, calcTestCases[i].expectedRedeem);

      // I can't set the ETH price will wait until we have oracles so I can mock
      // amount = _pool.simulateRedeem(calcTestCases[i].assetType, calcTestCases[i].inAmount);
      // assertEq(amount, calcTestCases[i].expectedRedeem);

      // Reset reserve state
      rToken.burn(governance, rToken.balanceOf(governance));
      rToken.burn(address(_pool), rToken.balanceOf(address(_pool)));
    }
  }

  function testRedeem() public {
    initializeTestCasesFixedEth();

    vm.startPrank(governance);
    Token rToken = Token(params.reserveToken);

    for (uint256 i = 0; i < calcTestCases.length; i++) {
      if (calcTestCases[i].inAmount == 0) {
        continue;
      }

      // Mint reserve tokens
      rToken.mint(governance, calcTestCases[i].TotalUnderlyingAssets);
      rToken.approve(address(poolFactory), calcTestCases[i].TotalUnderlyingAssets);

      // Create pool and approve deposit amount
      Pool _pool = Pool(poolFactory.CreatePool(params, calcTestCases[i].TotalUnderlyingAssets, calcTestCases[i].DebtAssets, calcTestCases[i].LeverageAssets));

      uint256 startBalance = rToken.balanceOf(governance);
      uint256 startBondBalance = BondToken(_pool.bondToken()).balanceOf(governance);
      uint256 startLevBalance = LeverageToken(_pool.lToken()).balanceOf(governance);

      vm.expectEmit(true, true, true, true);
      emit Pool.TokensRedeemed(governance, governance, calcTestCases[i].assetType, calcTestCases[i].inAmount, calcTestCases[i].expectedRedeem);

      // Call create and assert minted tokens
      uint256 amount = _pool.redeem(calcTestCases[i].assetType, calcTestCases[i].inAmount, 0);
      assertEq(amount, calcTestCases[i].expectedRedeem);

      uint256 endBalance = rToken.balanceOf(governance);
      uint256 endBondBalance = BondToken(_pool.bondToken()).balanceOf(governance);
      uint256 endLevBalance = LeverageToken(_pool.lToken()).balanceOf(governance);
      assertEq(amount, endBalance-startBalance);

      if (calcTestCases[i].assetType == Pool.TokenType.BOND) {
        assertEq(calcTestCases[i].inAmount, startBondBalance-endBondBalance);
        assertEq(0, endLevBalance-startLevBalance);
      } else {
        assertEq(0, endBondBalance-startBondBalance);
        assertEq(calcTestCases[i].inAmount, startLevBalance-endLevBalance);
      }

      // Reset reserve state
      rToken.burn(governance, rToken.balanceOf(governance));
      rToken.burn(address(_pool), rToken.balanceOf(address(_pool)));
    }
  }

  function testRedeemOnBehalfOf() public {
    vm.startPrank(governance);
    Token rToken = Token(params.reserveToken);

    for (uint256 i = 0; i < calcTestCases.length; i++) {
      if (calcTestCases[i].inAmount == 0) {
        continue;
      }

      // Mint reserve tokens
      rToken.mint(governance, calcTestCases[i].TotalUnderlyingAssets);
      rToken.approve(address(poolFactory), calcTestCases[i].TotalUnderlyingAssets);

      // Create pool and approve deposit amount
      Pool _pool = Pool(poolFactory.CreatePool(params, calcTestCases[i].TotalUnderlyingAssets, calcTestCases[i].DebtAssets, calcTestCases[i].LeverageAssets));

      uint256 startBalance = rToken.balanceOf(user2);
      uint256 startBondBalance = BondToken(_pool.bondToken()).balanceOf(governance);
      uint256 startLevBalance = LeverageToken(_pool.lToken()).balanceOf(governance);

      // Call create and assert minted tokens
      uint256 amount = _pool.redeem(calcTestCases[i].assetType, calcTestCases[i].inAmount, 0, block.timestamp, user2);
      assertEq(amount, calcTestCases[i].expectedRedeem);

      uint256 endBalance = rToken.balanceOf(user2);
      uint256 endBondBalance = BondToken(_pool.bondToken()).balanceOf(governance);
      uint256 endLevBalance = LeverageToken(_pool.lToken()).balanceOf(governance);
      assertEq(amount, endBalance-startBalance);

      if (calcTestCases[i].assetType == Pool.TokenType.BOND) {
        assertEq(calcTestCases[i].inAmount, startBondBalance-endBondBalance);
        assertEq(0, endLevBalance-startLevBalance);
      } else {
        assertEq(0, endBondBalance-startBondBalance);
        assertEq(calcTestCases[i].inAmount, startLevBalance-endLevBalance);
      }

      // Reset reserve state
      rToken.burn(governance, rToken.balanceOf(governance));
      rToken.burn(user2, rToken.balanceOf(user2));
      rToken.burn(address(_pool), rToken.balanceOf(address(_pool)));
    }
  }

  function testRedeemMinAmountExactSuccess() public {
    vm.startPrank(governance);
    Token rToken = Token(params.reserveToken);

    // Mint reserve tokens
    rToken.mint(governance, 10000001000);
    rToken.approve(address(poolFactory), 10000000000);

    // Create pool and approve deposit amount
    Pool _pool = Pool(poolFactory.CreatePool(params, 10000000000, 10000, 10000));
    rToken.approve(address(_pool), 1000);

    // Call create and assert minted tokens
    uint256 amount = _pool.redeem(Pool.TokenType.BOND, 1000, 33);
    assertEq(amount, 33);

    // Reset reserve state
    rToken.burn(governance, rToken.balanceOf(governance));
    rToken.burn(address(_pool), rToken.balanceOf(address(_pool)));
  }

  function testRedeemMinAmountError() public {
    vm.startPrank(governance);
    Token rToken = Token(params.reserveToken);

    // Mint reserve tokens
    rToken.mint(governance, 10000001000);
    rToken.approve(address(poolFactory), 10000000000);

    // Create pool and approve deposit amount
    Pool _pool = Pool(poolFactory.CreatePool(params, 10000000000, 10000, 10000));
    rToken.approve(address(_pool), 1000);

    // Call create and expect error
    vm.expectRevert(Pool.MinAmount.selector);
    _pool.redeem(Pool.TokenType.BOND, 1000, 34);

    // Reset reserve state
    rToken.burn(governance, rToken.balanceOf(governance));
    rToken.burn(address(_pool), rToken.balanceOf(address(_pool)));
  }

  function testSwap() public {
    initializeTestCasesFixedEth();

    vm.startPrank(governance);
    Token rToken = Token(params.reserveToken);

    for (uint256 i = 0; i < calcTestCases.length; i++) {
      if (calcTestCases[i].inAmount == 0) {
        continue;
      }

      // Mint reserve tokens
      rToken.mint(governance, calcTestCases[i].TotalUnderlyingAssets);
      rToken.approve(address(poolFactory), calcTestCases[i].TotalUnderlyingAssets);

      // Create pool and approve deposit amount
      Pool _pool = Pool(poolFactory.CreatePool(params, calcTestCases[i].TotalUnderlyingAssets, calcTestCases[i].DebtAssets, calcTestCases[i].LeverageAssets));

      uint256 startBalance = rToken.balanceOf(governance);
      uint256 startBondBalance = BondToken(_pool.bondToken()).balanceOf(governance);
      uint256 startLevBalance = LeverageToken(_pool.lToken()).balanceOf(governance);

      vm.expectEmit(true, true, true, true);
      emit Pool.TokensSwapped(governance, governance, calcTestCases[i].assetType, calcTestCases[i].inAmount, calcTestCases[i].expectedSwap);

      // Call create and assert minted tokens
      uint256 amount = _pool.swap(calcTestCases[i].assetType, calcTestCases[i].inAmount, 0);
      assertEq(amount, calcTestCases[i].expectedSwap);

      uint256 endBalance = rToken.balanceOf(governance);
      uint256 endBondBalance = BondToken(_pool.bondToken()).balanceOf(governance);
      uint256 endLevBalance = LeverageToken(_pool.lToken()).balanceOf(governance);

      assertEq(0, startBalance-endBalance);

      if (calcTestCases[i].assetType == Pool.TokenType.BOND) {
        assertEq(_pool.bondToken().totalSupply(), calcTestCases[i].DebtAssets - calcTestCases[i].inAmount);
        assertEq(_pool.lToken().totalSupply(), calcTestCases[i].LeverageAssets + amount);
        assertEq(calcTestCases[i].inAmount, startBondBalance-endBondBalance);
        assertEq(amount, endLevBalance-startLevBalance);
      } else {
        assertEq(_pool.bondToken().totalSupply(), calcTestCases[i].DebtAssets + amount);
        assertEq(_pool.lToken().totalSupply(), calcTestCases[i].LeverageAssets - calcTestCases[i].inAmount);
        assertEq(calcTestCases[i].inAmount, startLevBalance-endLevBalance);
        assertEq(amount, endBondBalance-startBondBalance);
      }

      // Reset reserve state
      rToken.burn(governance, rToken.balanceOf(governance));
      rToken.burn(address(_pool), rToken.balanceOf(address(_pool)));

      resetReentrancy(address(_pool));
    }
  }

  function testSwapOnBehalfOf() public {
    initializeTestCasesFixedEth();
    vm.startPrank(governance);
    Token rToken = Token(params.reserveToken);

    for (uint256 i = 0; i < calcTestCases.length; i++) {
      if (calcTestCases[i].inAmount == 0) {
        continue;
      }

      // Mint reserve tokens
      rToken.mint(governance, calcTestCases[i].TotalUnderlyingAssets);
      rToken.approve(address(poolFactory), calcTestCases[i].TotalUnderlyingAssets);

      // Create pool and approve deposit amount
      Pool _pool = Pool(poolFactory.CreatePool(params, calcTestCases[i].TotalUnderlyingAssets, calcTestCases[i].DebtAssets, calcTestCases[i].LeverageAssets));

      uint256 startBalance = rToken.balanceOf(governance);
      uint256 startBondBalance = BondToken(_pool.bondToken()).balanceOf(governance);
      uint256 startLevBalance = LeverageToken(_pool.lToken()).balanceOf(governance);

      uint256 startBondBalanceUser = BondToken(_pool.bondToken()).balanceOf(user2);
      uint256 startLevBalanceUser = LeverageToken(_pool.lToken()).balanceOf(user2);


      // Call create and assert minted tokens
      uint256 amount = _pool.swap(calcTestCases[i].assetType, calcTestCases[i].inAmount, 0, block.timestamp, user2);
      assertEq(amount, calcTestCases[i].expectedSwap);

      uint256 endBalance = rToken.balanceOf(governance);
      uint256 endBondBalance = BondToken(_pool.bondToken()).balanceOf(governance);
      uint256 endLevBalance = LeverageToken(_pool.lToken()).balanceOf(governance);

      uint256 endBondBalanceUser = BondToken(_pool.bondToken()).balanceOf(user2);
      uint256 endLevBalanceUser = LeverageToken(_pool.lToken()).balanceOf(user2);

      assertEq(0, startBalance-endBalance);

      if (calcTestCases[i].assetType == Pool.TokenType.BOND) {
        assertEq(_pool.bondToken().totalSupply(), calcTestCases[i].DebtAssets - calcTestCases[i].inAmount);
        assertEq(_pool.lToken().totalSupply(), calcTestCases[i].LeverageAssets + amount);
        assertEq(calcTestCases[i].inAmount, startBondBalance-endBondBalance);
        assertEq(amount, endLevBalanceUser-startLevBalanceUser);
      } else {
        assertEq(_pool.bondToken().totalSupply(), calcTestCases[i].DebtAssets + amount);
        assertEq(_pool.lToken().totalSupply(), calcTestCases[i].LeverageAssets - calcTestCases[i].inAmount);
        assertEq(calcTestCases[i].inAmount, startLevBalance-endLevBalance);
        assertEq(amount, endBondBalanceUser-startBondBalanceUser);
      }

      // Reset reserve state
      rToken.burn(governance, rToken.balanceOf(governance));
      rToken.burn(address(_pool), rToken.balanceOf(address(_pool)));
    }
  }

  function testGetPoolInfo() public {
    vm.startPrank(governance);
    Token rToken = Token(params.reserveToken);

    // Mint reserve tokens
    rToken.mint(governance, 10000000000);
    rToken.approve(address(poolFactory), 10000000000);

    // Create pool and approve deposit amount
    Pool _pool = Pool(poolFactory.CreatePool(params, 10000000000, 10000, 10000));
    
    Pool.PoolInfo memory info = _pool.getPoolInfo();
    assertEq(info.reserve, 10000000000);
    assertEq(info.bondSupply, 10000);
    assertEq(info.levSupply, 10000);
  }

  function testSetDistributionPeriod() public {
    vm.startPrank(governance);
    Pool _pool = Pool(poolFactory.CreatePool(params, 0, 0, 0));

    _pool.setDistributionPeriod(100);

    Pool.PoolInfo memory info = _pool.getPoolInfo();
    assertEq(info.distributionPeriod, 100);
  }

  function testSetDistributionPeriodErrorUnauthorized() public {
    vm.startPrank(governance);
    Pool _pool = Pool(poolFactory.CreatePool(params, 0, 0, 0));
    vm.stopPrank();

    vm.expectRevert();
    _pool.setDistributionPeriod(100);
  }

  function testSetFee() public {
    vm.startPrank(governance);
    Pool _pool = Pool(poolFactory.CreatePool(params, 0, 0, 0));

    _pool.setFee(100);

    Pool.PoolInfo memory info = _pool.getPoolInfo();
    assertEq(info.fee, 100);
  }

  function testSetFeeErrorUnauthorized() public {
    vm.startPrank(governance);
    Pool _pool = Pool(poolFactory.CreatePool(params, 0, 0, 0));
    vm.stopPrank();

    vm.expectRevert();
    _pool.setFee(100);
  }

  function testPause() public {
    vm.startPrank(governance);
    Pool _pool = Pool(poolFactory.CreatePool(params, 0, 0, 0));

    _pool.pause();

    vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
    _pool.setFee(0);

    vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
    _pool.create(Pool.TokenType.BOND, 0, 0);

    vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
    _pool.redeem(Pool.TokenType.BOND, 0, 0);

    vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
    _pool.swap(Pool.TokenType.BOND, 0, 0);

    _pool.unpause();
    _pool.setFee(100);

    Pool.PoolInfo memory info = _pool.getPoolInfo();
    assertEq(info.fee, 100);
  }

  function testNotEnoughBalanceInPool() public {
    Token rToken = Token(params.reserveToken);

    vm.startPrank(governance);
    rToken.mint(governance, 10000001000);
    rToken.approve(address(poolFactory), 10000000000);
    Pool _pool = Pool(poolFactory.CreatePool(params, 10000000000, 10000, 10000));
    vm.stopPrank();
    Token sharesToken = Token(_pool.couponToken());

    vm.startPrank(minter);
    // Mint less shares than required
    sharesToken.mint(address(_pool), 25*10**18);
    vm.stopPrank();

    vm.startPrank(address(_pool));
    _pool.bondToken().mint(user, 1000*10**18);
    vm.stopPrank();

    vm.startPrank(governance);
    //@todo figure out how to specify erc20 insufficient balance error
    vm.expectRevert();
    _pool.distribute();
    vm.stopPrank();
  }

  function testDistribute() public {
    Token rToken = Token(params.reserveToken);

    vm.startPrank(governance);
    rToken.mint(governance, 10000001000);
    rToken.approve(address(poolFactory), 10000000000);
    Pool _pool = Pool(poolFactory.CreatePool(params, 10000000000, 10000, 10000));
    Token sharesToken = Token(_pool.couponToken());
    uint256 initialBalance = 1000 * 10**18;
    uint256 expectedDistribution = (initialBalance + 10000) * params.sharesPerToken / 10**_pool.bondToken().SHARES_DECIMALS();
    vm.stopPrank();

    vm.startPrank(address(_pool));
    _pool.bondToken().mint(user, initialBalance);
    vm.stopPrank();

    vm.startPrank(minter);
    sharesToken.mint(address(_pool), expectedDistribution);
    vm.stopPrank();

    vm.startPrank(governance);
    vm.expectEmit(true, true, true, true);
    emit Pool.Distributed(expectedDistribution);
    _pool.distribute();
    vm.stopPrank();

    assertEq(sharesToken.balanceOf(address(distributor)), expectedDistribution);
  }

  function testDistributeMultiplePeriods() public {
    Token rToken = Token(params.reserveToken);

    vm.startPrank(governance);
    rToken.mint(governance, 10000001000);
    rToken.approve(address(poolFactory), 10000000000);
    Pool _pool = Pool(poolFactory.CreatePool(params, 10000000000, 10000, 10000));

    Token sharesToken = Token(_pool.couponToken());
    uint256 initialBalance = 1000 * 10**18;
    uint256 expectedDistribution = (initialBalance + 10000) * params.sharesPerToken / 10**_pool.bondToken().SHARES_DECIMALS();
    vm.stopPrank();
    
    vm.startPrank(address(_pool));
    _pool.bondToken().mint(user, initialBalance);
    vm.stopPrank();

    vm.startPrank(minter);
    sharesToken.mint(address(_pool), expectedDistribution * 3);
    vm.stopPrank();

    vm.startPrank(governance);
    _pool.distribute();
    _pool.distribute();
    _pool.distribute();
    vm.stopPrank();

    assertEq(sharesToken.balanceOf(address(distributor)), expectedDistribution * 3);
  }

  function testDistributeNoShares() public {
    Token rToken = Token(params.reserveToken);

    vm.startPrank(governance);
    rToken.mint(governance, 10000001000);
    rToken.approve(address(poolFactory), 10000000000);
    Pool _pool = Pool(poolFactory.CreatePool(params, 10000000000, 10000, 10000));
    vm.stopPrank();
    vm.startPrank(governance);
    vm.expectRevert();
    _pool.distribute();
    vm.stopPrank();
  }

  function testDistributeUnauthorized() public {
    Token rToken = Token(params.reserveToken);

    vm.startPrank(governance);
    rToken.mint(governance, 10000001000);
    rToken.approve(address(poolFactory), 10000000000);
    Pool _pool = Pool(poolFactory.CreatePool(params, 10000000000, 10000, 10000));
    vm.stopPrank();
    vm.expectRevert();
    _pool.distribute();
  }

  function testCreateRealistic() public {
    initializeRealisticTestCases();
    vm.startPrank(governance);
    Token rToken = Token(params.reserveToken);

    for (uint256 i = 0; i < calcTestCases.length; i++) {
      if (calcTestCases[i].inAmount == 0) {
        continue;
      }

      // Mint reserve tokens
      rToken.mint(governance, calcTestCases[i].TotalUnderlyingAssets + calcTestCases[i].inAmount);
      rToken.approve(address(poolFactory), calcTestCases[i].TotalUnderlyingAssets);

      setEthPrice(calcTestCases[i].ethPrice);

      // Create pool and approve deposit amount
      Pool _pool = Pool(poolFactory.CreatePool(params, calcTestCases[i].TotalUnderlyingAssets, calcTestCases[i].DebtAssets, calcTestCases[i].LeverageAssets));
      rToken.approve(address(_pool), calcTestCases[i].inAmount);

      uint256 startBondBalance = BondToken(_pool.bondToken()).balanceOf(governance);
      uint256 startLevBalance = LeverageToken(_pool.lToken()).balanceOf(governance);
      uint256 startReserveBalance = rToken.balanceOf(governance);

      // Call create and assert minted tokens
      uint256 amount = _pool.create(calcTestCases[i].assetType, calcTestCases[i].inAmount, 0);
      assertEq(amount, calcTestCases[i].expectedCreate);

      uint256 endBondBalance = BondToken(_pool.bondToken()).balanceOf(governance);
      uint256 endLevBalance = LeverageToken(_pool.lToken()).balanceOf(governance);
      uint256 endReserveBalance = rToken.balanceOf(governance);
      assertEq(calcTestCases[i].inAmount, startReserveBalance-endReserveBalance);

      if (calcTestCases[i].assetType == Pool.TokenType.BOND) {
        assertEq(amount, endBondBalance-startBondBalance);
        assertEq(0, endLevBalance-startLevBalance);
      } else {
        assertEq(0, endBondBalance-startBondBalance);
        assertEq(amount, endLevBalance-startLevBalance);
      }

      // Reset reserve state
      rToken.burn(governance, rToken.balanceOf(governance));
      rToken.burn(address(_pool), rToken.balanceOf(address(_pool)));
    }
  }

  function testRedeemRealistic() public {
    initializeRealisticTestCases();

    vm.startPrank(governance);
    Token rToken = Token(params.reserveToken);

    for (uint256 i = 0; i < calcTestCases.length; i++) {
      if (calcTestCases[i].inAmount == 0) {
        continue;
      }

      // Mint reserve tokens
      rToken.mint(governance, calcTestCases[i].TotalUnderlyingAssets);
      rToken.approve(address(poolFactory), calcTestCases[i].TotalUnderlyingAssets);

      setEthPrice(calcTestCases[i].ethPrice);

      // Create pool and approve deposit amount
      Pool _pool = Pool(poolFactory.CreatePool(params, calcTestCases[i].TotalUnderlyingAssets, calcTestCases[i].DebtAssets, calcTestCases[i].LeverageAssets));

      uint256 startBalance = rToken.balanceOf(governance);
      uint256 startBondBalance = BondToken(_pool.bondToken()).balanceOf(governance);
      uint256 startLevBalance = LeverageToken(_pool.lToken()).balanceOf(governance);

      // Call create and assert minted tokens
      uint256 amount = _pool.redeem(calcTestCases[i].assetType, calcTestCases[i].inAmount, 0);
      assertEq(amount, calcTestCases[i].expectedRedeem);

      uint256 endBalance = rToken.balanceOf(governance);
      uint256 endBondBalance = BondToken(_pool.bondToken()).balanceOf(governance);
      uint256 endLevBalance = LeverageToken(_pool.lToken()).balanceOf(governance);
      assertEq(amount, endBalance-startBalance);

      if (calcTestCases[i].assetType == Pool.TokenType.BOND) {
        assertEq(calcTestCases[i].inAmount, startBondBalance-endBondBalance);
        assertEq(0, endLevBalance-startLevBalance);
      } else {
        assertEq(0, endBondBalance-startBondBalance);
        assertEq(calcTestCases[i].inAmount, startLevBalance-endLevBalance);
      }

      // Reset reserve state
      rToken.burn(governance, rToken.balanceOf(governance));
      rToken.burn(address(_pool), rToken.balanceOf(address(_pool)));
    }
  }

  function testSwapRealistic() public {
    initializeRealisticTestCases();

    vm.startPrank(governance);
    Token rToken = Token(params.reserveToken);

    for (uint256 i = 0; i < calcTestCases.length; i++) {
      if (calcTestCases[i].inAmount == 0) {
        continue;
      }

      // Mint reserve tokens
      rToken.mint(governance, calcTestCases[i].TotalUnderlyingAssets);
      rToken.approve(address(poolFactory), calcTestCases[i].TotalUnderlyingAssets);

      setEthPrice(calcTestCases[i].ethPrice);

      // Create pool and approve deposit amount
      Pool _pool = Pool(poolFactory.CreatePool(params, calcTestCases[i].TotalUnderlyingAssets, calcTestCases[i].DebtAssets, calcTestCases[i].LeverageAssets));

      uint256 startBalance = rToken.balanceOf(governance);
      uint256 startBondBalance = BondToken(_pool.bondToken()).balanceOf(governance);
      uint256 startLevBalance = LeverageToken(_pool.lToken()).balanceOf(governance);

      // Call create and assert minted tokens
      uint256 amount = _pool.swap(calcTestCases[i].assetType, calcTestCases[i].inAmount, 0);
      assertEq(amount, calcTestCases[i].expectedSwap);

      uint256 endBalance = rToken.balanceOf(governance);
      uint256 endBondBalance = BondToken(_pool.bondToken()).balanceOf(governance);
      uint256 endLevBalance = LeverageToken(_pool.lToken()).balanceOf(governance);

      assertEq(0, startBalance-endBalance);

      if (calcTestCases[i].assetType == Pool.TokenType.BOND) {
        assertEq(_pool.bondToken().totalSupply(), calcTestCases[i].DebtAssets - calcTestCases[i].inAmount);
        assertEq(_pool.lToken().totalSupply(), calcTestCases[i].LeverageAssets + amount);
        assertEq(calcTestCases[i].inAmount, startBondBalance-endBondBalance);
        assertEq(amount, endLevBalance-startLevBalance);
      } else {
        assertEq(_pool.bondToken().totalSupply(), calcTestCases[i].DebtAssets + amount);
        assertEq(_pool.lToken().totalSupply(), calcTestCases[i].LeverageAssets - calcTestCases[i].inAmount);
        assertEq(calcTestCases[i].inAmount, startLevBalance-endLevBalance);
        assertEq(amount, endBondBalance-startBondBalance);
      }

      // Reset reserve state
      rToken.burn(governance, rToken.balanceOf(governance));
      rToken.burn(address(_pool), rToken.balanceOf(address(_pool)));
    }
  }
}
