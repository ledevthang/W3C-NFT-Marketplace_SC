// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title Clock auction for non-fungible tokens.
contract NftMarketplace {
    using SafeERC20 for IERC20;
    // Represents an auction on an NFT
    struct Listing {
        // Current owner of NFT
        address seller;
        // Price at beginning of listing
        uint128 startingPrice;
        address token;
        // Duration (in seconds) of listing
        uint64 duration;
        // Time when listing started
        // NOTE: 0 if this listing has been concluded
        uint64 startedAt;
        address highestBidder;
        uint256 highestPrice;
        bool isAuction;
    }

    // Cut owner takes on each listing, measured in basis points (1/100 of a percent).
    // Values 0-10,000 map to 0%-100%
    uint256 public ownerCut;

    address public owner;

    // Map from token ID to their corresponding listing.
    mapping(address => mapping(uint256 => Listing)) public listings;

    event ListingCreated(
        address indexed _nftAddress,
        uint256 indexed _tokenId,
        uint256 _startingPrice,
        address _token,
        uint256 _duration,
        address _seller,
        bool _isAuction
    );

    event BuySucceed(
        address indexed _nftAddress,
        uint256 indexed _tokenId,
        uint256 _price
    );

    event ListingCancelled(
        address indexed _nftAddress,
        uint256 indexed _tokenId
    );

    /// @dev Constructor creates a reference to the NFT ownership contract
    ///  and verifies the owner cut is in the valid range.
    /// @param _ownerCut - percent cut the owner takes on each listing, must be
    ///  between 0-10,000.
    constructor(uint256 _ownerCut, address _owner) {
        require(_ownerCut <= 10000);
        ownerCut = _ownerCut;
        owner = _owner;
    }

    /// @dev DON'T give me your money.
    //   function () external {}

    // Modifiers to check that inputs can be safely stored with a certain
    // number of bits. We use constants and multiple modifiers to save gas.
    modifier canBeStoredWith64Bits(uint256 _value) {
        require(_value <= 18446744073709551615);
        _;
    }

    modifier canBeStoredWith128Bits(uint256 _value) {
        require(_value < 340282366920938463463374607431768211455);
        _;
    }

    /// @dev Creates and begins a new listing.
    /// @param _nftAddress - address of a deployed contract implementing
    ///  the Nonfungible Interface.
    /// @param _tokenId - ID of token to listing, sender must be owner.
    /// @param _startingPrice - Price of item (in wei) at beginning of listing.
    /// @param _duration - Length of time to move between starting
    ///  price and ending price (in seconds).
    function createListing(
        address _nftAddress,
        uint256 _tokenId,
        uint256 _startingPrice,
        uint256 _duration,
        address _token,
        bool _isAuction
    )
        external
        canBeStoredWith128Bits(_startingPrice)
        canBeStoredWith64Bits(_duration)
    {
        address _seller = msg.sender;
        require(_owns(_nftAddress, _seller, _tokenId), "Not own nft");
        _checkApproved(_nftAddress, _tokenId);
        Listing memory _listing = Listing(
            _seller,
            uint128(_startingPrice),
            _token,
            uint64(_duration),
            uint64(block.timestamp),
            address(0),
            _startingPrice,
            _isAuction
        );
        require(_listing.duration >= 1 minutes, "Too short!");

        listings[_nftAddress][_tokenId] = _listing;

        emit ListingCreated(
            _nftAddress,
            _tokenId,
            uint256(_listing.startingPrice),
            _token,
            uint256(_listing.duration),
            _seller,
            _isAuction
        );
    }

    /// @dev Bids on an open listing, completing the listing and transferring
    ///  ownership of the NFT if enough Ether is supplied.
    /// @param _nftAddress - address of a deployed contract implementing
    ///  the Nonfungible Interface.
    /// @param _tokenId - ID of token to bid on.
    function bid(
        address _nftAddress,
        uint256 _tokenId,
        uint256 _price
    ) external payable {
        Listing storage _listing = listings[_nftAddress][_tokenId];
        require(_listing.isAuction == true, "Not auction");
        require(_isOnListing(_listing), "Auction not on");
        require(_price > _listing.highestPrice, "Invalid price");
        _listing.highestPrice = _price;
        _listing.highestBidder = msg.sender;
    }

    /// @dev Cancels an listing that hasn't been won yet.
    ///  Returns the NFT to original owner.
    /// @notice This is a state-modifying function that can
    ///  be called while the contract is paused.
    /// @param _nftAddress - Address of the NFT.
    /// @param _tokenId - ID of token on listing
    function cancelListing(address _nftAddress, uint256 _tokenId) external {
        Listing memory _listing = listings[_nftAddress][_tokenId];
        require(_isOnListing(_listing), "Auction not on");
        require(msg.sender == _listing.seller, "Not authorized");
        _cancelListing(_nftAddress, _tokenId);
    }

    /// @dev Returns true if the NFT is on listing.
    /// @param _listing - listing to check.
    function _isOnListing(Listing memory _listing)
        internal
        view
        returns (bool)
    {
        return (block.timestamp - _listing.startedAt < _listing.duration);
    }

    /// @dev Gets the NFT object from an address, validating that implementsERC721 is true.
    /// @param _nftAddress - Address of the NFT.
    function _getNftContract(address _nftAddress)
        internal
        pure
        returns (IERC721)
    {
        IERC721 candidateContract = IERC721(_nftAddress);
        // require(candidateContract.implementsERC721());
        return candidateContract;
    }

    /// @dev Returns true if the owner owns the token.
    /// @param _nftAddress - The address of the NFT.
    /// @param _owner - Address claiming to own the token.
    /// @param _tokenId - ID of token whose ownership to verify.
    function _owns(
        address _nftAddress,
        address _owner,
        uint256 _tokenId
    ) internal view returns (bool) {
        IERC721 _nftContract = _getNftContract(_nftAddress);
        return (_nftContract.ownerOf(_tokenId) == _owner);
    }

    /// @dev Cancels an listing unconditionally.
    function _cancelListing(address _nftAddress, uint256 _tokenId) internal {
        delete listings[_nftAddress][_tokenId];
        emit ListingCancelled(_nftAddress, _tokenId);
    }

    /// @dev Approve to transfer nft when win listing
    /// @param _nftAddress - The address of the NFT.
    /// @param _tokenId - ID of token whose approval to verify.
    function _checkApproved(address _nftAddress, uint256 _tokenId)
        internal
        view
    {
        IERC721 _nftContract = _getNftContract(_nftAddress);
        require(
            _nftContract.getApproved(_tokenId) == address(this),
            "Marketplace not approved for this nft"
        );
    }

    /// @dev For User who win listing can claim nft
    /// @param _nftAddress - The address of the NFT.
    /// @param _tokenId - ID of token to bid on.
    function purchaseNft(address _nftAddress, uint256 _tokenId) external {
        address _buyer = msg.sender;
        IERC721 _nftContract = _getNftContract(_nftAddress);
        Listing memory _listing = listings[_nftAddress][_tokenId];
        require(!_isOnListing(_listing), "listing is on");
        require(_listing.highestBidder == _buyer, "not winner");
        require(_listing.isAuction == true, "not auction");
        address _seller = _listing.seller;
        _nftContract.transferFrom(_seller, _buyer, _tokenId);

        uint256 cut_amount = (_listing.startingPrice * ownerCut) / 10000;
        IERC20(_listing.token).safeTransferFrom(_buyer, owner, cut_amount);
        IERC20(_listing.token).safeTransferFrom(
            _buyer,
            _seller,
            _listing.highestPrice - cut_amount
        );

        _cancelListing(_nftAddress, _tokenId);
        emit BuySucceed(_nftAddress, _tokenId, _listing.highestPrice);
    }

    /// @dev Buy nft on marketplace
    /// @param _nftAddress - The address of the NFT.
    /// @param _tokenId - ID of token to bid on.
    function buyNft(address _nftAddress, uint256 _tokenId) external {
        Listing memory _listing = listings[_nftAddress][_tokenId];
        require(_listing.isAuction == false, "is auction");
        address _buyer = msg.sender;
        IERC721 _nftContract = _getNftContract(_nftAddress);
        _nftContract.transferFrom(_listing.seller, _buyer, _tokenId);

        uint256 cut_amount = (_listing.startingPrice * ownerCut) / 10000;
        IERC20(_listing.token).safeTransferFrom(
            _buyer,
            _listing.seller,
            cut_amount
        );
        IERC20(_listing.token).safeTransferFrom(
            _buyer,
            _listing.seller,
            _listing.startingPrice - cut_amount
        );

        _cancelListing(_nftAddress, _tokenId);
        emit BuySucceed(_nftAddress, _tokenId, _listing.startingPrice);
    }
}
