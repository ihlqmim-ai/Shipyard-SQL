-- All foreign keys are DEFERRABLE so referenced rows can be added later in the same transaction.
-- Unreferenced PRIMARY KEY / UNIQUE are DEFERRABLE to allow temporary duplicates during multi-step changes.
-- Referenced PRIMARY KEY constraints stay non-deferrable because PostgreSQL requires this for foreign key targets.

-- Globally unique ISO 3166-1 alpha-2 country code (Singapore: SG).
--
-- CHECK enforces the country code format.
CREATE TABLE country (
    country_code CHAR(2),
    country_name VARCHAR NOT NULL,

    PRIMARY KEY (country_code),
    CHECK (country_code SIMILAR TO '[A-Z]{2}')
);

-- Globally unique GeoNames ID; digit counts vary, so we use INT.
-- Istanbul: 745044 [6 digits]; London: 2643743 [7 digits].
--
-- Merge part_of into city to enforce city's (1, 1) participation constraint (Exception 2).
--
-- CHECK enforces a non-negative city code because GeoNames city IDs are non-negative.
CREATE TABLE city (
    city_code INT,
    city_name VARCHAR NOT NULL,
    country_code CHAR(2) NOT NULL,

    PRIMARY KEY (city_code),
    FOREIGN KEY (country_code) REFERENCES country (country_code)
        ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    CHECK (city_code >= 0)
);

-- company_code: first three uppercase letters of the container ID (e.g. ADI).
--
-- Merge located_in into company to enforce company's (1, 1) participation constraint (Exception 2).
--
-- CHECK enforces the company code format.
CREATE TABLE company (
    company_code CHAR(3),
    company_name VARCHAR NOT NULL,
    address VARCHAR NOT NULL,
    postal_code VARCHAR NOT NULL,
    city_code INT NOT NULL,

    PRIMARY KEY (company_code),
    FOREIGN KEY (city_code) REFERENCES city (city_code)
        ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    CHECK (company_code SIMILAR TO '[A-Z]{3}')
);

-- CHECK ensures maximum_tiers is non-negative as a negative maximum is invalid.
-- Zero means no containers can be placed in yards of this type.
CREATE TABLE yard_type (
    yard_type_name VARCHAR,
    maximum_tiers INT NOT NULL,

    PRIMARY KEY (yard_type_name),
    CHECK (maximum_tiers >= 0)
);

-- No fixed yard code format specified; so we use VARCHAR.
--
-- Merge has_type into yard to enforce yard's (1, 1) participation constraint (Exception 2).
CREATE TABLE yard (
    yard_code VARCHAR,
    yard_type_name VARCHAR NOT NULL,

    PRIMARY KEY (yard_code),
    FOREIGN KEY (yard_type_name) REFERENCES yard_type (yard_type_name)
        ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

-- Weak entity owned by yard; (bay, row, tier) is its partial identity (Exception 3).
--
-- CHECK ensures bay and row are non-negative; numbering starts at 0.
-- CHECK ensures tier is positive; tier 1 is the ground level.
CREATE TABLE yard_position (
    yard_code VARCHAR,
    bay INT,
    row INT,
    tier INT,

    PRIMARY KEY (yard_code, bay, row, tier),
    FOREIGN KEY (yard_code) REFERENCES yard (yard_code)
        ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    CHECK (bay >= 0),
    CHECK (row >= 0),
    CHECK (tier >= 1)
);

-- No fixed berth code format specified so we use VARCHAR.
--
-- CHECK limits longitude to [-180, 180] and latitude to [-90, 90] degrees.
CREATE TABLE berth (
    berth_code VARCHAR,
    longitude DEC(8, 5) NOT NULL,
    latitude DEC(7, 5) NOT NULL,

    PRIMARY KEY (berth_code),
    CHECK (longitude BETWEEN -180 AND 180),
    CHECK (latitude BETWEEN -90 AND 90)
);

-- MMSI has 9 digits; IMO has 7.
--
-- Merge docked_at into ship to enforce ship's (1, 1) participation constraint (Exception 2).
-- Enforces berth's (0, 1) participation constraint with UNIQUE (Exception 1).
--
-- CHECK enforces the MMSI and IMO formats.
-- CHECK ensures length and width are positive; zero or negative dimensions are invalid.
CREATE TABLE ship (
    mmsi CHAR(9),
    imo CHAR(7) NOT NULL,
    call_sign VARCHAR NOT NULL,
    ship_name VARCHAR NOT NULL,
    length DEC NOT NULL,
    width DEC NOT NULL,
    berth_code VARCHAR NOT NULL,

    PRIMARY KEY (mmsi),
    UNIQUE (imo) DEFERRABLE INITIALLY DEFERRED,
    UNIQUE (call_sign) DEFERRABLE INITIALLY DEFERRED,
    UNIQUE (berth_code) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (berth_code) REFERENCES berth (berth_code)
        ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    CHECK (mmsi SIMILAR TO '[0-9]{9}'),
    CHECK (imo SIMILAR TO '[0-9]{7}'),
    CHECK (length > 0),
    CHECK (width > 0)
);

-- ISO 6346 container IDs: three uppercase letters, U, then seven digits.
--
-- CHECK ensures container_id matches this format.
--
-- Merge own into container to enforce container's (1, 1) participation constraint (Exception 2).
--
-- Merge stored_at and carried_by into container.
-- Location columns allow NULL for the unused option (e.g. on ship and not at yard, vice versa).
-- Enforces container's (0, 1) participation constraint with PRIMARY KEY (Exception 1).
-- Enforces yard_position's (0, 1) participation constraint with UNIQUE (Exception 1).
--
-- CHECK requires company_code to match the first three letters of container_id.
CREATE TABLE container (
    container_id CHAR(11),
    content_description VARCHAR NOT NULL,
    company_code CHAR(3) NOT NULL,
    yard_code VARCHAR,
    bay INT,
    row INT,
    tier INT,
    mmsi CHAR(9),

    PRIMARY KEY (container_id) DEFERRABLE INITIALLY DEFERRED,
    UNIQUE (yard_code, bay, row, tier) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (company_code) REFERENCES company (company_code)
        ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (yard_code, bay, row, tier)
        REFERENCES yard_position (yard_code, bay, row, tier)
        ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (mmsi) REFERENCES ship (mmsi)
        ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    CHECK (container_id SIMILAR TO '[A-Z]{3}U[0-9]{7}'),
    CHECK (company_code = SUBSTRING(container_id FROM 1 FOR 3))
);

-- (Trigger 1): There is no container that is neither on a ship nor in a yard.
CREATE OR REPLACE FUNCTION check_container_has_location()
RETURNS TRIGGER
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM container
        WHERE mmsi IS NULL
          AND (yard_code IS NULL OR bay IS NULL OR row IS NULL OR tier IS NULL)
    ) THEN
        RAISE EXCEPTION 'Container must be on a ship or in a yard';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER container_has_location
AFTER INSERT OR UPDATE ON container
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION check_container_has_location();

-- (Trigger 2): A container must either be on a ship or in a yard (but not both).
CREATE OR REPLACE FUNCTION check_container_exclusive_location()
RETURNS TRIGGER
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM container
        WHERE mmsi IS NOT NULL
          AND (yard_code IS NOT NULL OR bay IS NOT NULL OR row IS NOT NULL OR tier IS NOT NULL)
    ) THEN
        RAISE EXCEPTION 'Container cannot be both on a ship and in a yard';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER container_exclusive_location
AFTER INSERT OR UPDATE ON container
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION check_container_exclusive_location();

-- (Trigger 3): A container in a yard cannot be stacked higher than the maximum tier of that yard.
-- Check yard_position instead of container to prevent yard positions, even empty ones,
-- from exceeding their yard type's maximum tier. Containers reference yard_position
-- through a foreign key, so this also enforces the limit for containers.
CREATE OR REPLACE FUNCTION check_yard_position_maximum_tier()
RETURNS TRIGGER
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM yard_position p
        JOIN yard y ON y.yard_code = p.yard_code
        JOIN yard_type t ON t.yard_type_name = y.yard_type_name
        WHERE p.tier > t.maximum_tiers
    ) THEN
        RAISE EXCEPTION 'Yard position tier exceeds the maximum tier allowed for its yard';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER yard_position_maximum_tier
AFTER INSERT OR UPDATE ON yard_position
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION check_yard_position_maximum_tier();

-- If foreign keys are deferred but these triggers are set to IMMEDIATE, a yard position
-- may be inserted before its yard. The INNER JOIN skips that yard position because
-- the yard is missing. Including INSERT here checks the tier limit when the yard is added.
CREATE CONSTRAINT TRIGGER yard_maximum_tier
AFTER INSERT OR UPDATE ON yard
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION check_yard_position_maximum_tier();

-- If foreign keys are deferred but these triggers are set to IMMEDIATE, a yard position
-- may be inserted before its yard type. The INNER JOIN skips that yard position because
-- the yard type is missing. Including INSERT here checks the tier limit when the yard type is added.
CREATE CONSTRAINT TRIGGER yard_type_maximum_tier
AFTER INSERT OR UPDATE ON yard_type
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION check_yard_position_maximum_tier();

-- (Trigger 4): A container in a yard is either on the ground or on top of another container;
-- there are no "floating" containers.
CREATE OR REPLACE FUNCTION check_container_support()
RETURNS TRIGGER
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM container c
        WHERE c.yard_code IS NOT NULL
          AND c.tier > 1
          AND NOT EXISTS (
              SELECT 1
              FROM container b
              WHERE b.yard_code = c.yard_code
                AND b.bay = c.bay
                AND b.row = c.row
                AND b.tier = c.tier - 1
          )
    ) THEN
        RAISE EXCEPTION 'Container above ground must have another container directly below it';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER container_support
AFTER INSERT OR UPDATE OR DELETE ON container
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION check_container_support();
