// https://github.com/iearn-finance/jars/blob/master/contracts/controllers/StrategyControllerV1.sol

pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;
import "./lib/Initializable.sol";

import "./lib/erc20.sol";
import "./lib/safe-math.sol";

import "./interfaces/jar.sol";
import "./interfaces/jar-converter.sol";
import "./interfaces/strategy.sol";
import "./interfaces/strategyv2.sol";
import "./interfaces/onesplit.sol";
import "./interfaces/converter.sol";
import "./interfaces/univ3/IUniswapV3Pool.sol";

contract ControllerV7 is Initializable {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    address public constant burn = 0x000000000000000000000000000000000000dEaD;
    address public onesplit = 0xC586BeF4a0992C495Cf22e1aeEE4E446CECDee0E;

    address public governance;
    address public strategist;
    address public devfund;
    address public treasury;
    address public timelock;

    uint256 public convenienceFee = 100;
    uint256 public constant convenienceFeeMax = 100000;

    mapping(address => address) public jars;
    mapping(address => address) public strategies;
    mapping(address => mapping(address => address)) public converters;
    mapping(address => mapping(address => bool)) public approvedStrategies;
    mapping(address => bool) public approvedJarConverters;

    uint256 public split = 500;
    uint256 public constant max = 10000;

    function initialize() public initializer {}

    function setDevFund(address _devfund) public {
        require(msg.sender == governance, "!governance");
        devfund = _devfund;
    }

    function setTreasury(address _treasury) public {
        require(msg.sender == governance, "!governance");
        treasury = _treasury;
    }

    function setStrategist(address _strategist) public {
        require(msg.sender == governance, "!governance");
        strategist = _strategist;
    }

    function setGovernance(address _governance) public {
        require(msg.sender == governance, "!governance");
        governance = _governance;
    }

    function setTimelock(address _timelock) public {
        require(msg.sender == timelock, "!timelock");
        timelock = _timelock;
    }

    function setJar(address _pool, address _jar) public {
        require(msg.sender == strategist || msg.sender == governance, "!strategist");
        jars[_pool] = _jar;
    }

    function approveStrategy(address _pool, address _strategy) public {
        require(msg.sender == timelock, "!timelock");
        approvedStrategies[_pool][_strategy] = true;
    }

    function revokeStrategy(address _pool, address _strategy) public {
        require(msg.sender == governance, "!governance");
        require(strategies[_pool] != _strategy, "cannot revoke active strategy");
        approvedStrategies[_pool][_strategy] = false;
    }

    function setConvenienceFee(uint256 _convenienceFee) external {
        require(msg.sender == timelock, "!timelock");
        convenienceFee = _convenienceFee;
    }

    // in case of strategy stuck and if we need to relink the new strategy
    function removeJar(address _pool) public {
        require(msg.sender == strategist || msg.sender == governance, "!strategist");
        jars[_pool] = address(0);
    }

    // in case of strategy stuck and if we need to relink the new strategy
    function removeStrategy(address _pool) public {
        require(msg.sender == strategist || msg.sender == governance, "!strategist");
        strategies[_pool] = address(0);
    }

    function setStrategy(address _pool, address _strategy) public {
        require(msg.sender == strategist || msg.sender == governance, "!strategist");
        require(approvedStrategies[_pool][_strategy] == true, "!approved");

        address _current = strategies[_pool];
        if (_current != address(0)) {
            IStrategyV2(_current).withdrawAll();
        }
        strategies[_pool] = _strategy;
    }

    function setSplit(uint256 _split) public {
        require(msg.sender == governance, "!governance");
        require(_split <= max, "numerator cannot be greater than denominator");
        split = _split;
    }

    function setOneSplit(address _onesplit) public {
        require(msg.sender == governance, "!governance");
        onesplit = _onesplit;
    }

    function getUpperTick(address _pool) external view returns (int24) {
        return IStrategyV2(strategies[_pool]).tick_upper();
    }

    function getLowerTick(address _pool) external view returns (int24) {
        return IStrategyV2(strategies[_pool]).tick_lower();
    }

    function earn(
        address _pool,
        uint256 _token0Amount,
        uint256 _token1Amount
    ) public {
        address _strategy = strategies[_pool];
        address _want = IStrategyV2(_strategy).pool();
        require(_want == _pool, "pool address is different");

        if (_token0Amount > 0) IERC20(IUniswapV3Pool(_pool).token0()).safeTransfer(_strategy, _token0Amount);
        if (_token1Amount > 0) IERC20(IUniswapV3Pool(_pool).token1()).safeTransfer(_strategy, _token1Amount);
        IStrategyV2(_strategy).deposit();
    }

    function earn(address _token, uint256 _amount) public {
        address _strategy = strategies[_token];
        address _want = IStrategy(_strategy).want();
        if (_want != _token) {
            address converter = converters[_token][_want];
            IERC20(_token).safeTransfer(converter, _amount);
            _amount = Converter(converter).convert(_strategy);
            IERC20(_want).safeTransfer(_strategy, _amount);
        } else {
            IERC20(_token).safeTransfer(_strategy, _amount);
        }
        IStrategy(_strategy).deposit();
    }

    function liquidityOf(address _pool) external view returns (uint256) {
        return IStrategyV2(strategies[_pool]).liquidityOf();
    }

    function balanceOf(address _token) external view returns (uint256) {
        return IStrategy(strategies[_token]).balanceOf();
    }

    function withdrawAll(address _pool) public returns (uint256 a0, uint256 a1) {
        require(msg.sender == strategist || msg.sender == governance, "!strategist");
        (a0, a1) = IStrategyV2(strategies[_pool]).withdrawAll();
    }

    function inCaseTokensGetStuck(address _token, uint256 _amount) public {
        require(msg.sender == strategist || msg.sender == governance, "!governance");
        IERC20(_token).safeTransfer(msg.sender, _amount);
    }

    function inCaseStrategyTokenGetStuck(address _strategy, address _token) public {
        require(msg.sender == strategist || msg.sender == governance, "!governance");
        IStrategyV2(_strategy).withdraw(_token);
    }

    function withdraw(address _pool, uint256 _amount) public returns (uint256 a0, uint256 a1) {
        require(msg.sender == jars[_pool], "!jar");
        (a0, a1) = IStrategyV2(strategies[_pool]).withdraw(_amount);
    }

    function withdrawReward(address _token, uint256 _reward) public {
        require(msg.sender == jars[_token], "!jar");
        IStrategy(strategies[_token]).withdrawReward(_reward);
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) public pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function getExpectedReturn(
        address _strategy,
        address _token,
        uint256 parts
    ) public view returns (uint256 expected) {
        uint256 _balance = IERC20(_token).balanceOf(_strategy);
        address _want = IStrategy(_strategy).want();
        (expected, ) = OneSplitAudit(onesplit).getExpectedReturn(_token, _want, _balance, parts, 0);
    }

    // Only allows to withdraw non-core strategy tokens ~ this is over and above normal yield
    function yearn(
        address _strategy,
        address _token,
        uint256 parts
    ) public {
        require(msg.sender == strategist || msg.sender == governance, "!governance");
        // This contract should never have value in it, but just incase since this is a public call
        uint256 _before = IERC20(_token).balanceOf(address(this));
        IStrategy(_strategy).withdraw(_token);
        uint256 _after = IERC20(_token).balanceOf(address(this));
        if (_after > _before) {
            uint256 _amount = _after.sub(_before);
            address _want = IStrategy(_strategy).want();
            uint256[] memory _distribution;
            uint256 _expected;
            _before = IERC20(_want).balanceOf(address(this));
            IERC20(_token).safeApprove(onesplit, 0);
            IERC20(_token).safeApprove(onesplit, _amount);
            (_expected, _distribution) = OneSplitAudit(onesplit).getExpectedReturn(_token, _want, _amount, parts, 0);
            OneSplitAudit(onesplit).swap(_token, _want, _amount, _expected, _distribution, 0);
            _after = IERC20(_want).balanceOf(address(this));
            if (_after > _before) {
                _amount = _after.sub(_before);
                uint256 _treasury = _amount.mul(split).div(max);
                earn(_want, _amount.sub(_treasury));
                IERC20(_want).safeTransfer(treasury, _treasury);
            }
        }
    }

    function _execute(address _target, bytes memory _data) internal returns (bytes memory response) {
        require(_target != address(0), "!target");

        // call contract in current context
        assembly {
            let succeeded := delegatecall(sub(gas(), 5000), _target, add(_data, 0x20), mload(_data), 0, 0)
            let size := returndatasize()

            response := mload(0x40)
            mstore(0x40, add(response, and(add(add(size, 0x20), 0x1f), not(0x1f))))
            mstore(response, size)
            returndatacopy(add(response, 0x20), 0, size)

            switch iszero(succeeded)
            case 1 {
                // throw if delegatecall failed
                revert(add(response, 0x20), size)
            }
        }
    }
}
